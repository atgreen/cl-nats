;;; protocol.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Anthony Green <green@moxielogic.com>

(in-package #:cl-nats)

;;; Wire protocol encode/decode. No I/O -- returns strings/octets for writing,
;;; and takes lines/octets for parsing.

(defvar *crlf* (coerce '(#\Return #\Newline) 'string))

;;; --- Formatting (outbound) ---

(defun format-connect (info-alist)
  "Format a CONNECT command. INFO-ALIST is an alist of connection options."
  (let ((json (com.inuoe.jzon:stringify info-alist)))
    (concatenate 'string "CONNECT " json *crlf*)))

(defun format-pub (subject payload &key reply-to)
  "Format a PUB command. PAYLOAD is octets. Returns string for header + octets for payload."
  (let* ((size (length payload))
         (header (if reply-to
                     (format nil "PUB ~a ~a ~d~a" subject reply-to size *crlf*)
                     (format nil "PUB ~a ~d~a" subject size *crlf*))))
    (values header payload)))

(defun format-hpub (subject payload header-octets &key reply-to)
  "Format an HPUB command. PAYLOAD and HEADER-OCTETS are octets."
  (let* ((hdr-len (length header-octets))
         (total-len (+ hdr-len (length payload)))
         (header (if reply-to
                     (format nil "HPUB ~a ~a ~d ~d~a" subject reply-to hdr-len total-len *crlf*)
                     (format nil "HPUB ~a ~d ~d~a" subject hdr-len total-len *crlf*))))
    (values header header-octets payload)))

(defun format-sub (subject sid &key queue-group)
  "Format a SUB command."
  (if queue-group
      (format nil "SUB ~a ~a ~a~a" subject queue-group sid *crlf*)
      (format nil "SUB ~a ~a~a" subject sid *crlf*)))

(defun format-unsub (sid &key max-msgs)
  "Format an UNSUB command."
  (if max-msgs
      (format nil "UNSUB ~a ~d~a" sid max-msgs *crlf*)
      (format nil "UNSUB ~a~a" sid *crlf*)))

(defun format-ping ()
  "Format a PING command."
  (concatenate 'string "PING" *crlf*))

(defun format-pong ()
  "Format a PONG command."
  (concatenate 'string "PONG" *crlf*))

;;; --- Parsing (inbound) ---

(defstruct server-info
  "Parsed INFO from the NATS server."
  server-id server-name version go proto
  host port headers max-payload
  tls-required tls-available
  auth-required connect-urls client-id client-ip)

(defun parse-info-json (json-string)
  "Parse the INFO JSON payload into a server-info struct."
  (let ((obj (com.inuoe.jzon:parse json-string :key-fn #'identity)))
    (make-server-info
     :server-id (gethash "server_id" obj)
     :server-name (gethash "server_name" obj)
     :version (gethash "version" obj)
     :go (gethash "go" obj)
     :proto (gethash "proto" obj)
     :host (gethash "host" obj)
     :port (gethash "port" obj)
     :headers (gethash "headers" obj)
     :max-payload (gethash "max_payload" obj)
     :tls-required (gethash "tls_required" obj)
     :tls-available (gethash "tls_available" obj)
     :auth-required (gethash "auth_required" obj)
     :connect-urls (let ((urls (gethash "connect_urls" obj)))
                     (when urls (coerce urls 'list)))
     :client-id (gethash "client_id" obj)
     :client-ip (gethash "client_ip" obj))))

(defstruct parsed-msg
  "Parsed MSG line fields."
  subject sid reply-to byte-count)

(defstruct parsed-hmsg
  "Parsed HMSG line fields."
  subject sid reply-to header-bytes total-bytes)

(defun parse-msg-line (line)
  "Parse a MSG line: MSG <subject> <sid> [reply-to] <#bytes>
   Returns a parsed-msg struct."
  (let ((parts (cl-ppcre:split "\\s+" line)))
    ;; parts: (\"MSG\" subject sid [reply-to] bytes)
    (cond
      ((= (length parts) 4)
       ;; MSG subject sid bytes
       (make-parsed-msg :subject (second parts)
                        :sid (parse-integer (third parts))
                        :reply-to nil
                        :byte-count (parse-integer (fourth parts))))
      ((= (length parts) 5)
       ;; MSG subject sid reply-to bytes
       (make-parsed-msg :subject (second parts)
                        :sid (parse-integer (third parts))
                        :reply-to (fourth parts)
                        :byte-count (parse-integer (fifth parts))))
      (t (error 'nats-protocol-error :line line
                                     :message "Invalid MSG line")))))

(defun parse-hmsg-line (line)
  "Parse an HMSG line: HMSG <subject> <sid> [reply-to] <#header-bytes> <#total-bytes>
   Returns a parsed-hmsg struct."
  (let ((parts (cl-ppcre:split "\\s+" line)))
    (cond
      ((= (length parts) 5)
       ;; HMSG subject sid hdr-bytes total-bytes
       (make-parsed-hmsg :subject (second parts)
                         :sid (parse-integer (third parts))
                         :reply-to nil
                         :header-bytes (parse-integer (fourth parts))
                         :total-bytes (parse-integer (fifth parts))))
      ((= (length parts) 6)
       ;; HMSG subject sid reply-to hdr-bytes total-bytes
       (make-parsed-hmsg :subject (second parts)
                         :sid (parse-integer (third parts))
                         :reply-to (fourth parts)
                         :header-bytes (parse-integer (fifth parts))
                         :total-bytes (parse-integer (sixth parts))))
      (t (error 'nats-protocol-error :line line
                                     :message "Invalid HMSG line")))))

(defun parse-server-op (line)
  "Dispatch on the first word of a line from the server.
   Returns (values op data) where op is a keyword and data depends on op.
   :info -> JSON string
   :msg -> parsed-msg struct
   :hmsg -> parsed-hmsg struct
   :ping -> nil
   :pong -> nil
   :ok -> nil
   :err -> error message string"
  (cond
    ((starts-with-p "INFO " line)
     (values :info (subseq line 5)))
    ((starts-with-p "MSG " line)
     (values :msg (parse-msg-line line)))
    ((starts-with-p "HMSG " line)
     (values :hmsg (parse-hmsg-line line)))
    ((string= line "PING")
     (values :ping nil))
    ((string= line "PONG")
     (values :pong nil))
    ((string= line "+OK")
     (values :ok nil))
    ((starts-with-p "-ERR " line)
     (values :err (string-trim '(#\Space #\' #\") (subseq line 5))))
    (t
     (error 'nats-protocol-error :line line
                                 :message "Unknown server operation"))))

(defun starts-with-p (prefix string)
  "Return T if STRING starts with PREFIX."
  (and (>= (length string) (length prefix))
       (string= string prefix :end1 (length prefix))))
