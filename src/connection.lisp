;;; connection.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Anthony Green <green@moxielogic.com>

(in-package #:cl-nats)

;;; Connection state machine, reader thread, reconnection, ping/pong.

(defstruct server-entry
  "A NATS server endpoint."
  (host "127.0.0.1" :type string)
  (port 4222 :type integer)
  (tls-p nil :type boolean))

(defstruct request-channel
  "Channel for request-reply waiting."
  (lock (bt2:make-lock :name "request-channel-lock"))
  (cv (bt2:make-condition-variable :name "request-channel-cv"))
  (response nil)
  (done-p nil :type boolean))

(defstruct connection
  "NATS connection state."
  ;; Configuration
  (servers nil :type list)              ; list of server-entry
  (name nil :type (or null string))
  (user nil :type (or null string))
  (pass nil :type (or null string))
  (auth-token nil :type (or null string))
  (tls-name nil :type (or null string)) ; SNI hostname override
  (verbose nil :type boolean)
  (pedantic nil :type boolean)
  (no-echo nil :type boolean)
  ;; Reconnection
  (reconnect-allowed t :type boolean)
  (reconnect-wait 2 :type number)       ; base wait in seconds
  (reconnect-max-wait 60 :type number)
  (reconnect-jitter 0.1 :type number)   ; jitter fraction
  (reconnect-buffer-size (* 8 1024 1024) :type integer) ; 8MB
  (max-reconnect-attempts -1 :type integer) ; -1 = unlimited
  ;; Ping/Pong
  (ping-interval 120 :type number)      ; seconds
  (max-outstanding-pings 2 :type integer)
  (outstanding-pings 0 :type integer)
  ;; State
  (status :disconnected :type keyword)  ; :disconnected :connecting :connected :reconnecting :closed
  (status-lock (bt2:make-lock :name "connection-status-lock"))
  ;; Transport
  (transport nil)
  ;; Write synchronization
  (write-lock (bt2:make-lock :name "connection-write-lock"))
  ;; Server info
  (server-info nil)
  ;; Subscriptions
  (registry (make-subscription-registry))
  ;; Request-reply map: inbox-subject -> request-channel
  (request-map (make-hash-table :test #'equal))
  (request-map-lock (bt2:make-lock :name "request-map-lock"))
  ;; Threads
  (reader-thread nil)
  (ping-thread nil)
  ;; Cancel context
  (cancel-context nil)
  (cancel-fn nil)
  ;; Reconnect buffer
  (reconnect-buffer nil :type list)
  (reconnect-buffer-bytes 0 :type integer)
  ;; Event callbacks
  (on-disconnect nil :type (or null function))
  (on-reconnect nil :type (or null function))
  (on-error nil :type (or null function))
  (on-close nil :type (or null function))
  ;; Server index for round-robin
  (server-index 0 :type integer))

(defun connection-set-status (conn new-status)
  "Thread-safe status update."
  (bt2:with-lock-held ((connection-status-lock conn))
    (setf (connection-status conn) new-status)))

(defun connection-get-status (conn)
  "Thread-safe status read."
  (bt2:with-lock-held ((connection-status-lock conn))
    (connection-status conn)))

;;; --- Handshake ---

(defun build-connect-json (conn)
  "Build the CONNECT JSON payload as a hash table for jzon."
  (let ((obj (make-hash-table :test #'equal)))
    (setf (gethash "verbose" obj) (connection-verbose conn))
    (setf (gethash "pedantic" obj) (connection-pedantic conn))
    (setf (gethash "lang" obj) "common-lisp")
    (setf (gethash "version" obj) "0.1.0")
    (setf (gethash "protocol" obj) 1)
    (setf (gethash "headers" obj) t)
    (setf (gethash "no_responders" obj) t)
    (when (connection-name conn)
      (setf (gethash "name" obj) (connection-name conn)))
    (when (connection-user conn)
      (setf (gethash "user" obj) (connection-user conn)))
    (when (connection-pass conn)
      (setf (gethash "pass" obj) (connection-pass conn)))
    (when (connection-auth-token conn)
      (setf (gethash "auth_token" obj) (connection-auth-token conn)))
    (when (connection-no-echo conn)
      (setf (gethash "echo" obj) nil))
    obj))

(defun do-handshake (conn)
  "Perform the NATS connection handshake on the current transport.
   Read INFO, optionally upgrade TLS, send CONNECT, send PING, read PONG."
  (let ((transport (connection-transport conn)))
    ;; 1. Read INFO
    (let ((line (transport-read-line transport)))
      (unless line
        (error 'nats-connection-error :message "No INFO from server"))
      (multiple-value-bind (op data) (parse-server-op line)
        (unless (eql op :info)
          (error 'nats-protocol-error :line line
                                      :message "Expected INFO"))
        (let ((info (parse-info-json data)))
          (setf (connection-server-info conn) info)
          ;; Merge connect_urls
          (when (server-info-connect-urls info)
            (merge-connect-urls conn (server-info-connect-urls info)))
          ;; TLS upgrade if required
          (when (and (server-info-tls-required info)
                     (not (transport-tls-p transport)))
            (transport-upgrade-tls transport
                                   (or (connection-tls-name conn)
                                       (transport-host transport))
                                   :cancel-context (connection-cancel-context conn))))))
    ;; 2. Send CONNECT
    (let ((connect-str (format-connect (build-connect-json conn))))
      (transport-write-string transport connect-str))
    ;; 3. Send PING
    (transport-write-string transport (format-ping))
    ;; 4. Read PONG (or -ERR), skipping any +OK lines (verbose mode)
    (loop for attempts below 10 do
      (let ((line (transport-read-line transport)))
        (unless line
          (error 'nats-connection-error :message "No PONG from server"))
        (multiple-value-bind (op data) (parse-server-op line)
          (cond
            ((eql op :pong) (return-from do-handshake t))
            ((eql op :ok) nil)           ; skip +OK, read next line
            ((eql op :err)
             (error 'nats-server-error :server-message data))
            (t
             (error 'nats-protocol-error :line line
                                         :message "Expected PONG")))))
          finally (error 'nats-protocol-error
                         :line ""
                         :message "No PONG received after handshake"))))

(defun merge-connect-urls (conn url-strings)
  "Merge discovered server URLs into the server list, deduplicating.
   URLs without a scheme inherit TLS mode from the current transport."
  (let ((existing (make-hash-table :test #'equal))
        (current-tls-p (and (connection-transport conn)
                            (transport-tls-p (connection-transport conn)))))
    (dolist (s (connection-servers conn))
      (setf (gethash (format nil "~a:~a" (server-entry-host s) (server-entry-port s))
                     existing)
            t))
    (dolist (url url-strings)
      (let ((has-scheme (search "://" url)))
        (multiple-value-bind (host port tls-p) (parse-nats-url
                                                 (if has-scheme
                                                     url
                                                     (concatenate 'string "nats://" url)))
          ;; Inherit TLS from current connection when scheme is absent
          (unless has-scheme
            (setf tls-p current-tls-p))
          (let ((key (format nil "~a:~a" host port)))
            (unless (gethash key existing)
              (setf (gethash key existing) t)
              (push (make-server-entry :host host :port port :tls-p tls-p)
                    (connection-servers conn)))))))))

;;; --- Reader thread ---

(defun start-reader-thread (conn)
  "Start the reader loop in a new thread."
  (setf (connection-reader-thread conn)
        (bt2:make-thread
         (lambda () (reader-loop conn))
         :name "nats-reader")))

(defun reader-loop (conn)
  "Read lines from the transport, dispatch operations."
  (handler-case
      (loop
        (let ((status (connection-get-status conn)))
          (when (or (eql status :closed) (eql status :disconnected))
            (return)))
        (let ((line (transport-read-line (connection-transport conn))))
          (unless line
            ;; EOF = disconnected
            (handle-disconnect conn)
            (return))
          (multiple-value-bind (op data) (parse-server-op line)
            (case op
              (:msg (handle-msg conn data))
              (:hmsg (handle-hmsg conn data))
              (:ping (handle-ping conn))
              (:pong (handle-pong conn))
              (:ok nil)                 ; verbose mode ack
              (:err (handle-server-error conn data))
              (:info
               ;; Server may re-send INFO (e.g., cluster change)
               (let ((info (parse-info-json data)))
                 (setf (connection-server-info conn) info)
                 (when (server-info-connect-urls info)
                   (merge-connect-urls conn (server-info-connect-urls info)))))
              (otherwise nil)))))
    (nats-connection-error ()
      (handle-disconnect conn))
    (error ()
      (handle-disconnect conn))))

(defun handle-msg (conn parsed)
  "Handle a MSG: read payload bytes, create message, dispatch."
  (let* ((byte-count (parsed-msg-byte-count parsed))
         (transport (connection-transport conn))
         (payload (transport-read-bytes transport byte-count)))
    ;; Read trailing CRLF
    (transport-read-line transport)
    (let ((msg (make-message :subject (parsed-msg-subject parsed)
                             :sid (parsed-msg-sid parsed)
                             :reply-to (parsed-msg-reply-to parsed)
                             :data payload)))
      ;; Check if this is a response to a pending request
      (let ((chan (lookup-request-channel conn (parsed-msg-subject parsed))))
        (if chan
            (fulfill-request-channel chan msg)
            (registry-dispatch (connection-registry conn)
                               (parsed-msg-sid parsed) msg
                               :on-error (connection-on-error conn)))))))

(defun handle-hmsg (conn parsed)
  "Handle an HMSG: read payload bytes, split headers, create message, dispatch."
  (let* ((total-bytes (parsed-hmsg-total-bytes parsed))
         (header-bytes (parsed-hmsg-header-bytes parsed))
         (transport (connection-transport conn))
         (all-data (transport-read-bytes transport total-bytes)))
    ;; Read trailing CRLF
    (transport-read-line transport)
    (let* ((header-octets (subseq all-data 0 header-bytes))
           (payload (subseq all-data header-bytes))
           (headers nil)
           (status nil))
      (multiple-value-setq (headers status)
        (parse-headers header-octets))
      ;; Check for no-responders (status 503)
      (when (and status (= status 503))
        ;; This is a no-responders notification for a request
        (let ((chan (lookup-request-channel conn (parsed-hmsg-subject parsed))))
          (when chan
            (fulfill-request-channel-error chan
                                           (make-condition 'nats-no-responders
                                                           :subject (parsed-hmsg-subject parsed)))
            (return-from handle-hmsg))))
      (let ((msg (make-message :subject (parsed-hmsg-subject parsed)
                               :sid (parsed-hmsg-sid parsed)
                               :reply-to (parsed-hmsg-reply-to parsed)
                               :data payload
                               :headers headers)))
        (let ((chan (lookup-request-channel conn (parsed-hmsg-subject parsed))))
          (if chan
              (fulfill-request-channel chan msg)
              (registry-dispatch (connection-registry conn)
                                 (parsed-hmsg-sid parsed) msg
                                 :on-error (connection-on-error conn))))))))

(defun handle-ping (conn)
  "Respond to server PING with PONG."
  (connection-write-string conn (format-pong)))

(defun handle-pong (conn)
  "Handle server PONG: reset outstanding pings counter."
  (bt2:with-lock-held ((connection-status-lock conn))
    (when (> (connection-outstanding-pings conn) 0)
      (decf (connection-outstanding-pings conn)))))

(defun handle-server-error (conn err-msg)
  "Handle -ERR from server."
  (when (connection-on-error conn)
    (ignore-errors
      (funcall (connection-on-error conn)
               (make-condition 'nats-server-error :server-message err-msg)))))

(defun handle-disconnect (conn)
  "Handle unexpected disconnection. Initiate reconnection if allowed."
  (let ((status (connection-get-status conn)))
    (when (or (eql status :closed) (eql status :reconnecting))
      (return-from handle-disconnect))
    (connection-set-status conn :reconnecting)
    ;; Call on-disconnect callback
    (when (connection-on-disconnect conn)
      (ignore-errors (funcall (connection-on-disconnect conn))))
    ;; Close transport
    (when (connection-transport conn)
      (ignore-errors (transport-close (connection-transport conn)))
      (setf (connection-transport conn) nil))
    ;; Attempt reconnection
    (cond
      ((connection-reconnect-allowed conn)
       (bt2:make-thread
        (lambda () (reconnect-loop conn))
        :name "nats-reconnect"))
      (t
       (connection-set-status conn :closed)
       (when (connection-on-close conn)
         (ignore-errors (funcall (connection-on-close conn))))))))

;;; --- Request-reply support ---

(defun lookup-request-channel (conn subject)
  "Look up a pending request channel by subject."
  (bt2:with-lock-held ((connection-request-map-lock conn))
    (gethash subject (connection-request-map conn))))

(defun register-request-channel (conn subject channel)
  "Register a request channel for an inbox subject."
  (bt2:with-lock-held ((connection-request-map-lock conn))
    (setf (gethash subject (connection-request-map conn)) channel)))

(defun unregister-request-channel (conn subject)
  "Remove a request channel."
  (bt2:with-lock-held ((connection-request-map-lock conn))
    (remhash subject (connection-request-map conn))))

(defun fulfill-request-channel (channel message)
  "Deliver a response message to a waiting request."
  (bt2:with-lock-held ((request-channel-lock channel))
    (setf (request-channel-response channel) message
          (request-channel-done-p channel) t)
    (bt2:condition-notify (request-channel-cv channel))))

(defun fulfill-request-channel-error (channel condition)
  "Signal an error to a waiting request."
  (bt2:with-lock-held ((request-channel-lock channel))
    (setf (request-channel-response channel) condition
          (request-channel-done-p channel) t)
    (bt2:condition-notify (request-channel-cv channel))))

;;; --- Ping timer ---

(defun start-ping-timer (conn)
  "Start the ping timer thread."
  (when (> (connection-ping-interval conn) 0)
    (setf (connection-ping-thread conn)
          (bt2:make-thread
           (lambda () (ping-timer-loop conn))
           :name "nats-ping-timer"))))

(defun ping-timer-loop (conn)
  "Periodically send PING and detect stale connections."
  (handler-case
      (loop
        (let ((status (connection-get-status conn)))
          (when (member status '(:closed :disconnected :reconnecting))
            (return)))
        (sleep (connection-ping-interval conn))
        (let ((status (connection-get-status conn)))
          (when (member status '(:closed :disconnected :reconnecting))
            (return)))
        ;; Check outstanding pings
        (when (>= (connection-outstanding-pings conn)
                  (connection-max-outstanding-pings conn))
          ;; Stale connection
          (handle-disconnect conn)
          (return))
        ;; Send PING
        (bt2:with-lock-held ((connection-status-lock conn))
          (incf (connection-outstanding-pings conn)))
        (ignore-errors
          (connection-write-string conn (format-ping))))
    (error () nil)))

;;; --- Reconnection ---

(defun reconnect-loop (conn)
  "Try to reconnect to servers with exponential backoff."
  (let ((attempt 0)
        (max-attempts (connection-max-reconnect-attempts conn)))
    (loop
      ;; Check if closed
      (when (eql (connection-get-status conn) :closed)
        (return))
      ;; Check max attempts
      (when (and (/= max-attempts -1) (>= attempt max-attempts))
        (connection-set-status conn :closed)
        (when (connection-on-close conn)
          (ignore-errors (funcall (connection-on-close conn))))
        (return))
      ;; Calculate backoff
      (when (> attempt 0)
        (let* ((base-wait (connection-reconnect-wait conn))
               (max-wait (connection-reconnect-max-wait conn))
               (wait (min (* base-wait (expt 2 (1- attempt))) max-wait))
               (jitter (* wait (connection-reconnect-jitter conn)
                         (- (random 2.0) 1.0)))
               (total-wait (max 0.1 (+ wait jitter))))
          (sleep total-wait)))
      ;; Try each server
      (let ((servers (connection-servers conn))
            (connected nil))
        (dotimes (i (length servers))
          (when (eql (connection-get-status conn) :closed)
            (return))
          (let* ((idx (mod (+ (connection-server-index conn) i)
                          (length servers)))
                 (server (nth idx servers)))
            (handler-case
                (progn
                  (setf (connection-server-index conn) (1+ idx))
                  (attempt-reconnect conn server)
                  (setf connected t)
                  (return))
              (error () nil))))
        (when connected
          (return)))
      (incf attempt))))

(defun attempt-reconnect (conn server)
  "Try to reconnect to a single server. Signals error on failure."
  (let ((transport (transport-connect (server-entry-host server)
                                      (server-entry-port server)
                                      :tls (server-entry-tls-p server)
                                      :cancel-context (connection-cancel-context conn))))
    (setf (connection-transport conn) transport)
    ;; Perform handshake
    (do-handshake conn)
    ;; Replay subscriptions
    (replay-subscriptions conn)
    ;; Flush reconnect buffer
    (flush-reconnect-buffer conn)
    ;; Reset pings
    (bt2:with-lock-held ((connection-status-lock conn))
      (setf (connection-outstanding-pings conn) 0))
    ;; Update status
    (connection-set-status conn :connected)
    ;; Start new reader and ping threads
    (start-reader-thread conn)
    (start-ping-timer conn)
    ;; Callback
    (when (connection-on-reconnect conn)
      (ignore-errors (funcall (connection-on-reconnect conn))))))

(defun replay-subscriptions (conn)
  "Re-subscribe all active subscriptions after reconnect."
  (dolist (sub (registry-all-subscriptions (connection-registry conn)))
    (let ((cmd (format-sub (subscription-subject sub)
                           (subscription-sid sub)
                           :queue-group (subscription-queue-group sub))))
      (transport-write-string (connection-transport conn) cmd))))

(defun flush-reconnect-buffer (conn)
  "Send any buffered messages after reconnection."
  (bt2:with-lock-held ((connection-write-lock conn))
    (dolist (data (nreverse (connection-reconnect-buffer conn)))
      (ignore-errors
        (etypecase data
          ((vector (unsigned-byte 8))
           (transport-write-octets (connection-transport conn) data))
          (string
           (transport-write-string (connection-transport conn) data)))))
    (setf (connection-reconnect-buffer conn) nil
          (connection-reconnect-buffer-bytes conn) 0)))

;;; --- Write path ---

(defun connection-write-string (conn string)
  "Thread-safe write to the transport. Buffers during reconnect."
  (let ((status (connection-get-status conn)))
    (cond
      ((eql status :connected)
       (bt2:with-lock-held ((connection-write-lock conn))
         (transport-write-string (connection-transport conn) string)))
      ((eql status :reconnecting)
       ;; Buffer the write
       (bt2:with-lock-held ((connection-write-lock conn))
         (let ((bytes (length (string-to-octets string))))
           (when (> (+ (connection-reconnect-buffer-bytes conn) bytes)
                    (connection-reconnect-buffer-size conn))
             (error 'nats-connection-error
                    :message "Reconnect buffer full"))
           (push string (connection-reconnect-buffer conn))
           (incf (connection-reconnect-buffer-bytes conn) bytes))))
      ((eql status :closed)
       (error 'nats-connection-error :message "Connection is closed"))
      (t
       (error 'nats-connection-error :message "Not connected")))))

(defun connection-write-octets (conn octets)
  "Thread-safe write octets to the transport."
  (let ((status (connection-get-status conn)))
    (cond
      ((eql status :connected)
       (bt2:with-lock-held ((connection-write-lock conn))
         (transport-write-octets (connection-transport conn) octets)))
      ((eql status :closed)
       (error 'nats-connection-error :message "Connection is closed"))
      (t
       (error 'nats-connection-error :message "Not connected")))))

(defun buffer-reconnect-frame (conn &rest parts)
  "Buffer a complete wire frame (list of strings and octet vectors) for replay
   after reconnect. All parts are stored as octet vectors to preserve binary data."
  (bt2:with-lock-held ((connection-write-lock conn))
    (let ((total-size 0)
          (octet-parts nil))
      ;; Convert all parts to octets
      (dolist (part parts)
        (let ((octets (etypecase part
                        (string (string-to-octets part))
                        ((vector (unsigned-byte 8)) part))))
          (push octets octet-parts)
          (incf total-size (length octets))))
      ;; Check buffer limit
      (when (> (+ (connection-reconnect-buffer-bytes conn) total-size)
               (connection-reconnect-buffer-size conn))
        (error 'nats-connection-error :message "Reconnect buffer full"))
      ;; Store as a single concatenated octet vector
      (let ((frame (make-array total-size :element-type '(unsigned-byte 8)))
            (pos 0))
        (dolist (octets (nreverse octet-parts))
          (replace frame octets :start1 pos)
          (incf pos (length octets)))
        (push frame (connection-reconnect-buffer conn))
        (incf (connection-reconnect-buffer-bytes conn) total-size)))))

(defun connection-write-pub (conn header-string payload crlf-string)
  "Write a complete PUB command: header + payload + CRLF, atomically."
  (let ((status (connection-get-status conn)))
    (cond
      ((eql status :connected)
       (bt2:with-lock-held ((connection-write-lock conn))
         (let ((transport (connection-transport conn)))
           (transport-write-string transport header-string)
           (transport-write-octets transport payload)
           (transport-write-string transport crlf-string))))
      ((eql status :reconnecting)
       (buffer-reconnect-frame conn header-string payload crlf-string))
      ((eql status :closed)
       (error 'nats-connection-error :message "Connection is closed"))
      (t
       (error 'nats-connection-error :message "Not connected")))))

(defun connection-write-hpub (conn header-string header-octets payload crlf-string)
  "Write a complete HPUB command atomically."
  (let ((status (connection-get-status conn)))
    (cond
      ((eql status :connected)
       (bt2:with-lock-held ((connection-write-lock conn))
         (let ((transport (connection-transport conn)))
           (transport-write-string transport header-string)
           (transport-write-octets transport header-octets)
           (transport-write-octets transport payload)
           (transport-write-string transport crlf-string))))
      ((eql status :reconnecting)
       (buffer-reconnect-frame conn header-string header-octets payload crlf-string))
      ((eql status :closed)
       (error 'nats-connection-error :message "Connection is closed"))
      (t
       (error 'nats-connection-error :message "Not connected")))))

;;; --- Connection lifecycle ---

(defun connection-connect (conn)
  "Connect to the NATS server. Tries servers in order."
  (connection-set-status conn :connecting)
  ;; Create top-level cancel context
  (multiple-value-bind (ctx cancel-fn)
      (cl-cancel:with-cancel (cl-cancel:background))
    (setf (connection-cancel-context conn) ctx
          (connection-cancel-fn conn) cancel-fn))
  (let ((servers (connection-servers conn))
        (last-error nil))
    (dolist (server servers)
      (handler-case
          (let ((transport (transport-connect
                            (server-entry-host server)
                            (server-entry-port server)
                            :tls (server-entry-tls-p server)
                            :cancel-context (connection-cancel-context conn))))
            (setf (connection-transport conn) transport)
            (do-handshake conn)
            (connection-set-status conn :connected)
            (start-reader-thread conn)
            (start-ping-timer conn)
            (return-from connection-connect conn))
        (error (e)
          (setf last-error e)
          (when (connection-transport conn)
            (ignore-errors (transport-close (connection-transport conn)))
            (setf (connection-transport conn) nil)))))
    ;; All servers failed
    (connection-set-status conn :disconnected)
    (error 'nats-connection-error
           :message (format nil "Failed to connect to any server: ~a" last-error))))

(defun join-thread-with-timeout (thread timeout)
  "Wait for THREAD to finish, with TIMEOUT seconds. Destroy if it doesn't."
  (when (and thread (bt2:thread-alive-p thread))
    ;; Try interrupt first to break out of blocking I/O
    (ignore-errors
      (bt2:interrupt-thread thread
        (lambda () (invoke-restart (find-restart 'abort)))))
    ;; Poll for completion
    (let ((deadline (+ (get-internal-real-time)
                       (* timeout internal-time-units-per-second))))
      (loop while (and (bt2:thread-alive-p thread)
                       (< (get-internal-real-time) deadline))
            do (sleep 0.05)))
    ;; Force destroy if still alive
    (when (bt2:thread-alive-p thread)
      (ignore-errors (bt2:destroy-thread thread)))))

(defun connection-close (conn)
  "Gracefully close the connection."
  (when (eql (connection-get-status conn) :closed)
    (return-from connection-close))
  (connection-set-status conn :closed)
  ;; Cancel all operations
  (when (connection-cancel-fn conn)
    (funcall (connection-cancel-fn conn))
    (setf (connection-cancel-fn conn) nil))
  ;; Close transport (unblocks reader thread from I/O)
  (when (connection-transport conn)
    (ignore-errors (transport-close (connection-transport conn)))
    (setf (connection-transport conn) nil))
  ;; Wait for reader thread with timeout
  (join-thread-with-timeout (connection-reader-thread conn) 2)
  ;; Wait for ping thread with timeout
  (join-thread-with-timeout (connection-ping-thread conn) 2)
  ;; Clear subscriptions
  (registry-clear (connection-registry conn))
  ;; Callback
  (when (connection-on-close conn)
    (ignore-errors (funcall (connection-on-close conn)))))
