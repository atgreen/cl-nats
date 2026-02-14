;;; t/server-harness.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Anthony Green <green@moxielogic.com>

(in-package #:cl-nats/tests)

;;; Manages nats-server processes for integration tests.

(defvar *nats-server-path* "nats-server")

(defstruct nats-server-process
  "A managed nats-server process."
  process
  port
  pid)

(defun find-free-port ()
  "Find a free TCP port by binding to port 0 and reading the assigned port."
  (let ((socket (usocket:socket-listen "127.0.0.1" 0 :reuse-address t)))
    (unwind-protect
         (usocket:get-local-port socket)
      (usocket:socket-close socket))))

(defun start-nats-server (&key (port (find-free-port)))
  "Start a nats-server on the given port. Returns a nats-server-process struct."
  (let* ((process (uiop:launch-program
                   (list *nats-server-path*
                         "-p" (princ-to-string port)
                         "-a" "127.0.0.1")
                   :output :interactive
                   :error-output :interactive)))
    ;; Give server time to start
    (sleep 0.5)
    ;; Verify it's up by trying to connect
    (let ((ready nil)
          (attempts 0))
      (loop while (and (not ready) (< attempts 20)) do
        (handler-case
            (let ((sock (usocket:socket-connect "127.0.0.1" port
                                                :element-type '(unsigned-byte 8)
                                                :timeout 1)))
              (usocket:socket-close sock)
              (setf ready t))
          (error ()
            (incf attempts)
            (sleep 0.25))))
      (unless ready
        (uiop:terminate-process process :urgent t)
        (error "nats-server failed to start on port ~a after ~a attempts" port attempts)))
    (make-nats-server-process :process process
                              :port port)))

(defun stop-nats-server (server)
  "Stop a nats-server process."
  (when (and server (nats-server-process-process server))
    (ignore-errors
      (uiop:terminate-process (nats-server-process-process server) :urgent nil))
    ;; Give it a moment to shut down cleanly
    (sleep 0.3)
    ;; Force kill if still running
    (ignore-errors
      (uiop:terminate-process (nats-server-process-process server) :urgent t))
    (ignore-errors
      (uiop:wait-process (nats-server-process-process server)))))

(defun server-url (server)
  "Return the nats:// URL for a server."
  (format nil "nats://127.0.0.1:~a" (nats-server-process-port server)))

(defmacro with-nats-server ((var &key (port nil port-p)) &body body)
  "Execute BODY with a running nats-server bound to VAR.
   Automatically stops the server on exit."
  `(let ((,var (start-nats-server ,@(when port-p `(:port ,port)))))
     (unwind-protect
          (locally ,@body)
       (stop-nats-server ,var))))

(defmacro with-connected-client ((client-var server) &body body)
  "Execute BODY with a connected NATS client for the given server."
  `(let ((,client-var (nats:make-client :servers (list (server-url ,server))
                                        :reconnect-allowed nil
                                        :ping-interval 0)))
     (unwind-protect
          (progn
            (nats:connect ,client-var)
            ,@body)
       (ignore-errors (nats:close-connection ,client-var)))))

(defun wait-for (predicate &key (timeout 5) (interval 0.05))
  "Poll PREDICATE until it returns non-NIL or TIMEOUT seconds elapse.
   Returns the predicate's value, or NIL on timeout."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (let ((result (funcall predicate)))
        (when result (return result)))
      (when (>= (get-internal-real-time) deadline)
        (return nil))
      (sleep interval))))
