;;; conditions.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Anthony Green <green@moxielogic.com>

(in-package #:cl-nats)

(define-condition nats-error (error)
  ((message :initarg :message :reader nats-error-message :initform ""))
  (:report (lambda (c s)
             (format s "NATS error: ~a" (nats-error-message c)))))

(define-condition nats-connection-error (nats-error)
  ((host :initarg :host :reader nats-connection-error-host :initform nil)
   (port :initarg :port :reader nats-connection-error-port :initform nil))
  (:report (lambda (c s)
             (format s "NATS connection error~@[ (~a:~a)~]: ~a"
                     (nats-connection-error-host c)
                     (nats-connection-error-port c)
                     (nats-error-message c)))))

(define-condition nats-timeout-error (nats-error)
  ((timeout :initarg :timeout :reader nats-timeout-error-timeout :initform nil))
  (:report (lambda (c s)
             (format s "NATS timeout~@[ after ~as~]: ~a"
                     (nats-timeout-error-timeout c)
                     (nats-error-message c)))))

(define-condition nats-protocol-error (nats-error)
  ((line :initarg :line :reader nats-protocol-error-line :initform nil))
  (:report (lambda (c s)
             (format s "NATS protocol error~@[ (line: ~s)~]: ~a"
                     (nats-protocol-error-line c)
                     (nats-error-message c)))))

(define-condition nats-server-error (nats-error)
  ((server-message :initarg :server-message
                   :reader nats-server-error-server-message
                   :initform nil))
  (:report (lambda (c s)
             (format s "NATS server error: ~a"
                     (or (nats-server-error-server-message c)
                         (nats-error-message c))))))

(define-condition nats-stale-connection (nats-connection-error)
  ()
  (:report (lambda (c s)
             (declare (ignore c))
             (format s "NATS stale connection: too many outstanding pings"))))

(define-condition nats-no-responders (nats-error)
  ((subject :initarg :subject :reader nats-no-responders-subject :initform nil))
  (:report (lambda (c s)
             (format s "NATS no responders for subject: ~a"
                     (nats-no-responders-subject c)))))

(define-condition nats-max-payload-error (nats-error)
  ((size :initarg :size :reader nats-max-payload-error-size :initform nil)
   (max-size :initarg :max-size :reader nats-max-payload-error-max-size :initform nil))
  (:report (lambda (c s)
             (format s "NATS payload too large: ~a bytes (max ~a)"
                     (nats-max-payload-error-size c)
                     (nats-max-payload-error-max-size c)))))
