;;; client.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Anthony Green <green@moxielogic.com>

(in-package #:cl-nats)

;;; Public high-level API. Thin wrappers around connection.

;;; --- Message struct ---

(defstruct message
  "A NATS message."
  (subject "" :type string)
  (sid 0 :type integer)
  (reply-to nil :type (or null string))
  (data #() :type (vector (unsigned-byte 8)))
  (headers nil :type list))

(defun message-data-string (message)
  "Return the message data as a UTF-8 string."
  (octets-to-string (message-data message)))

;;; --- Client struct ---

(defstruct (client (:constructor %make-client))
  "A NATS client."
  (connection nil :type (or null connection)))

;;; --- Lifecycle ---

(defun make-client (&key (servers '("nats://127.0.0.1:4222"))
                      name user pass auth-token tls-name
                      (verbose nil) (pedantic nil) (no-echo nil)
                      (reconnect-allowed t)
                      (reconnect-wait 2)
                      (reconnect-max-wait 60)
                      (max-reconnect-attempts -1)
                      (reconnect-buffer-size (* 8 1024 1024))
                      (ping-interval 120)
                      (max-outstanding-pings 2))
  "Create a new NATS client. Does not connect -- call CONNECT to establish connection.

   SERVERS is a list of NATS URL strings (nats://host:port or tls://host:port).
   NAME is an optional client name sent to the server.
   USER and PASS are credentials for authentication.
   AUTH-TOKEN is a token for token-based authentication.
   TLS-NAME overrides the hostname used for TLS SNI.
   VERBOSE enables verbose protocol mode.
   PEDANTIC enables pedantic protocol checking.
   NO-ECHO prevents the server from echoing published messages back.
   RECONNECT-ALLOWED enables automatic reconnection on disconnect.
   RECONNECT-WAIT is the base wait in seconds between reconnect attempts.
   RECONNECT-MAX-WAIT caps the exponential backoff.
   MAX-RECONNECT-ATTEMPTS limits reconnection attempts (-1 = unlimited).
   RECONNECT-BUFFER-SIZE is the max bytes to buffer during reconnection.
   PING-INTERVAL is seconds between keep-alive pings.
   MAX-OUTSTANDING-PINGS is the max unanswered pings before disconnect."
  (let ((server-entries
          (mapcar (lambda (url)
                    (multiple-value-bind (host port tls-p) (parse-nats-url url)
                      (make-server-entry :host host :port port :tls-p tls-p)))
                  (if (listp servers) servers (list servers)))))
    (%make-client
     :connection (make-connection
                  :servers server-entries
                  :name name
                  :user user
                  :pass pass
                  :auth-token auth-token
                  :tls-name tls-name
                  :verbose verbose
                  :pedantic pedantic
                  :no-echo no-echo
                  :reconnect-allowed reconnect-allowed
                  :reconnect-wait reconnect-wait
                  :reconnect-max-wait reconnect-max-wait
                  :max-reconnect-attempts max-reconnect-attempts
                  :reconnect-buffer-size reconnect-buffer-size
                  :ping-interval ping-interval
                  :max-outstanding-pings max-outstanding-pings))))

(defun connect (client)
  "Connect the client to the NATS server. Returns the client."
  (connection-connect (client-connection client))
  client)

(defun close-connection (client)
  "Gracefully close the client connection."
  (connection-close (client-connection client))
  (values))

(defun client-status (client)
  "Return the client connection status as a keyword:
   :disconnected, :connecting, :connected, :reconnecting, or :closed."
  (connection-get-status (client-connection client)))

;;; --- Event callbacks ---

(defun on-disconnect (client)
  "Return the on-disconnect callback."
  (connection-on-disconnect (client-connection client)))

(defun (setf on-disconnect) (fn client)
  "Set the on-disconnect callback. FN takes no arguments."
  (setf (connection-on-disconnect (client-connection client)) fn))

(defun on-reconnect (client)
  "Return the on-reconnect callback."
  (connection-on-reconnect (client-connection client)))

(defun (setf on-reconnect) (fn client)
  "Set the on-reconnect callback. FN takes no arguments."
  (setf (connection-on-reconnect (client-connection client)) fn))

(defun on-error (client)
  "Return the on-error callback."
  (connection-on-error (client-connection client)))

(defun (setf on-error) (fn client)
  "Set the on-error callback. FN takes one argument (condition)."
  (setf (connection-on-error (client-connection client)) fn))

(defun on-close (client)
  "Return the on-close callback."
  (connection-on-close (client-connection client)))

(defun (setf on-close) (fn client)
  "Set the on-close callback. FN takes no arguments."
  (setf (connection-on-close (client-connection client)) fn))

;;; --- Pub/Sub ---

(defun publish (client subject data &key reply-to headers)
  "Publish DATA to SUBJECT. DATA can be a string or octet vector.
   REPLY-TO is an optional reply subject.
   HEADERS is an optional alist of headers."
  (let* ((conn (client-connection client))
         (payload (etypecase data
                    (string (string-to-octets data))
                    ((vector (unsigned-byte 8)) data)
                    (null (make-array 0 :element-type '(unsigned-byte 8)))))
         (info (connection-server-info conn)))
    ;; Max payload check
    (when (and info
              (server-info-max-payload info)
              (> (length payload) (server-info-max-payload info)))
      (error 'nats-max-payload-error
             :size (length payload)
             :max-size (server-info-max-payload info)))
    (if headers
        ;; HPUB with headers
        (let ((header-octets (serialize-headers headers)))
          (multiple-value-bind (header-line hdr-oct pay)
              (format-hpub subject payload header-octets :reply-to reply-to)
            (declare (ignore hdr-oct pay))
            (connection-write-hpub conn header-line header-octets payload *crlf*)))
        ;; PUB without headers
        (multiple-value-bind (header-line pay)
            (format-pub subject payload :reply-to reply-to)
          (declare (ignore pay))
          (connection-write-pub conn header-line payload *crlf*))))
  (values))

(defun subscribe (client subject callback &key queue-group)
  "Subscribe to SUBJECT. CALLBACK is called with a message struct for each message.
   QUEUE-GROUP is an optional queue group name for load balancing.
   Returns a subscription object."
  (let* ((conn (client-connection client))
         (sid (next-sid))
         (sub (make-subscription :sid sid
                                 :subject subject
                                 :queue-group queue-group
                                 :callback callback)))
    ;; Register
    (registry-add (connection-registry conn) sub)
    ;; Send SUB command
    (connection-write-string conn (format-sub subject sid :queue-group queue-group))
    sub))

(defun unsubscribe (client subscription &key max-msgs)
  "Unsubscribe from a subscription. If MAX-MSGS is provided,
   auto-unsubscribe after receiving that many messages."
  (let* ((conn (client-connection client))
         (sid (subscription-sid subscription)))
    (when max-msgs
      (setf (subscription-max-msgs subscription) max-msgs))
    ;; Send UNSUB command
    (connection-write-string conn (format-unsub sid :max-msgs max-msgs))
    ;; If no max-msgs, remove immediately
    (unless max-msgs
      (setf (subscription-closed-p subscription) t)
      (registry-remove (connection-registry conn) sid)))
  (values))

;;; --- Request-Reply ---

(defun request (client subject data &key (timeout 5) headers)
  "Send a request to SUBJECT and wait for a reply.
   DATA can be a string or octet vector.
   TIMEOUT is seconds to wait (default 5). Uses cl-cancel for timeout management.
   HEADERS is an optional alist of headers.
   Returns the reply message, or signals nats-timeout-error."
  (let* ((conn (client-connection client))
         (inbox (generate-inbox))
         (channel (make-request-channel))
         (sid (next-sid))
         (sub (make-subscription :sid sid
                                 :subject inbox
                                 :callback nil
                                 :max-msgs 1)))
    ;; Register request channel
    (register-request-channel conn inbox channel)
    ;; Register and send subscription for inbox
    (registry-add (connection-registry conn) sub)
    (connection-write-string conn (format-sub inbox sid))
    ;; Auto-unsub after 1 message
    (connection-write-string conn (format-unsub sid :max-msgs 1))
    (unwind-protect
         (progn
           ;; Publish the request
           (publish client subject data :reply-to inbox :headers headers)
           ;; Wait for response with timeout using cl-cancel
           (handler-case
               (cl-cancel:with-timeout-context (ctx timeout)
                 (bt2:with-lock-held ((request-channel-lock channel))
                   (loop until (request-channel-done-p channel)
                         do (bt2:condition-wait (request-channel-cv channel)
                                                (request-channel-lock channel)
                                                :timeout 0.5)
                            ;; Check cancellation
                            (when (cl-cancel:done-p ctx)
                              (error 'nats-timeout-error
                                     :timeout timeout
                                     :message "Request timed out"))))
                 ;; Check result
                 (let ((response (request-channel-response channel)))
                   (if (typep response 'condition)
                       (error response)
                       response)))
             (cl-cancel:deadline-exceeded ()
               (error 'nats-timeout-error
                      :timeout timeout
                      :message "Request timed out"))))
      ;; Cleanup
      (unregister-request-channel conn inbox)
      (setf (subscription-closed-p sub) t)
      (registry-remove (connection-registry conn) sid))))
