;;; transport.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Anthony Green <green@moxielogic.com>

(in-package #:cl-nats)

;;; TCP socket + pure-tls + flexi-stream I/O layer.

(defstruct transport
  "Low-level transport wrapper around a TCP socket and stream."
  socket          ; usocket socket object
  stream          ; flexi-stream (bivalent, line+binary)
  raw-stream      ; underlying socket stream (before TLS)
  host
  port
  tls-p           ; T if TLS is active
  cancel-cleanup) ; cleanup function from close-stream-on-cancel

(defun transport-connect (host port &key tls cancel-context)
  "Open a TCP connection to HOST:PORT, returning a transport struct.
   If TLS is true, upgrade the connection with pure-tls."
  (handler-case
      (let* ((socket (usocket:socket-connect host port
                                             :element-type '(unsigned-byte 8)))
             (raw-stream (usocket:socket-stream socket))
             (stream nil)
             (transport nil))
        (cond
          (tls
           ;; TLS upgrade
           (let ((tls-stream (pure-tls:make-tls-client-stream
                              raw-stream
                              :hostname host
                              :request-context cancel-context)))
             (setf stream (flexi-streams:make-flexi-stream
                           tls-stream
                           :external-format :utf-8))
             (setf transport (make-transport :socket socket
                                            :stream stream
                                            :raw-stream raw-stream
                                            :host host
                                            :port port
                                            :tls-p t))))
          (t
           ;; Plain TCP
           (setf stream (flexi-streams:make-flexi-stream
                         raw-stream
                         :external-format :utf-8))
           (setf transport (make-transport :socket socket
                                          :stream stream
                                          :raw-stream raw-stream
                                          :host host
                                          :port port
                                          :tls-p nil))))
        ;; Set up cancel-based stream closing if context provided
        (when cancel-context
          (setf (transport-cancel-cleanup transport)
                (cl-cancel:close-stream-on-cancel
                 (transport-stream transport) cancel-context)))
        transport)
    (usocket:socket-error (e)
      (error 'nats-connection-error
             :host host :port port
             :message (format nil "Socket error: ~a" e)))
    (error (e)
      (error 'nats-connection-error
             :host host :port port
             :message (format nil "Connection failed: ~a" e)))))

(defun transport-upgrade-tls (transport host &key cancel-context)
  "Upgrade an existing plain transport to TLS. Replaces the stream in-place."
  (handler-case
      (let* ((raw-stream (transport-raw-stream transport))
             (tls-stream (pure-tls:make-tls-client-stream
                          raw-stream
                          :hostname host
                          :request-context cancel-context))
             (flexi (flexi-streams:make-flexi-stream
                     tls-stream
                     :external-format :utf-8)))
        ;; Clean up old cancel monitor
        (when (transport-cancel-cleanup transport)
          (funcall (transport-cancel-cleanup transport))
          (setf (transport-cancel-cleanup transport) nil))
        (setf (transport-stream transport) flexi
              (transport-tls-p transport) t)
        ;; Set up new cancel monitor
        (when cancel-context
          (setf (transport-cancel-cleanup transport)
                (cl-cancel:close-stream-on-cancel flexi cancel-context)))
        transport)
    (error (e)
      (error 'nats-connection-error
             :host (transport-host transport)
             :port (transport-port transport)
             :message (format nil "TLS upgrade failed: ~a" e)))))

(defun transport-write-string (transport string)
  "Write a string to the transport stream and flush."
  (handler-case
      (let ((stream (transport-stream transport)))
        (write-string string stream)
        (force-output stream))
    (error (e)
      (error 'nats-connection-error
             :host (transport-host transport)
             :port (transport-port transport)
             :message (format nil "Write error: ~a" e)))))

(defun transport-write-octets (transport octets)
  "Write raw octets to the transport stream and flush."
  (handler-case
      (let ((stream (transport-stream transport)))
        (write-sequence octets stream)
        (force-output stream))
    (error (e)
      (error 'nats-connection-error
             :host (transport-host transport)
             :port (transport-port transport)
             :message (format nil "Write error: ~a" e)))))

(defun transport-write-flush (transport)
  "Flush the transport stream."
  (handler-case
      (force-output (transport-stream transport))
    (error (e)
      (error 'nats-connection-error
             :host (transport-host transport)
             :port (transport-port transport)
             :message (format nil "Flush error: ~a" e)))))

(defun transport-read-line (transport)
  "Read a CRLF-terminated line from the transport (without the CRLF).
   Returns the line as a string, or NIL on EOF."
  (handler-case
      (let ((line (read-line (transport-stream transport) nil nil)))
        (when line
          ;; Strip trailing CR if present (read-line strips LF)
          (if (and (> (length line) 0)
                   (char= (char line (1- (length line))) #\Return))
              (subseq line 0 (1- (length line)))
              line)))
    (error (e)
      (error 'nats-connection-error
             :host (transport-host transport)
             :port (transport-port transport)
             :message (format nil "Read error: ~a" e)))))

(defun transport-read-bytes (transport n)
  "Read exactly N bytes from the transport as octets."
  (handler-case
      (let* ((buf (make-array n :element-type '(unsigned-byte 8)))
             (stream (transport-stream transport))
             (pos 0))
        ;; Switch to binary temporarily
        (setf (flexi-streams:flexi-stream-external-format stream)
              :latin-1)
        (unwind-protect
             (loop while (< pos n) do
               (let ((byte (read-byte stream nil nil)))
                 (cond
                   (byte
                    (setf (aref buf pos) byte)
                    (incf pos))
                   (t
                    (error 'nats-connection-error
                           :host (transport-host transport)
                           :port (transport-port transport)
                           :message "Unexpected EOF reading payload")))))
          (setf (flexi-streams:flexi-stream-external-format stream)
                :utf-8))
        buf)
    (nats-connection-error (e) (error e))
    (error (e)
      (error 'nats-connection-error
             :host (transport-host transport)
             :port (transport-port transport)
             :message (format nil "Read error: ~a" e)))))

(defun transport-close (transport)
  "Close the transport, releasing all resources."
  (when transport
    ;; Cancel the stream monitor
    (when (transport-cancel-cleanup transport)
      (ignore-errors (funcall (transport-cancel-cleanup transport)))
      (setf (transport-cancel-cleanup transport) nil))
    ;; Close the stream and socket
    (when (transport-stream transport)
      (ignore-errors (close (transport-stream transport)))
      (setf (transport-stream transport) nil))
    (when (transport-socket transport)
      (ignore-errors (usocket:socket-close (transport-socket transport)))
      (setf (transport-socket transport) nil))))
