;;; subscription.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Anthony Green <green@moxielogic.com>

(in-package #:cl-nats)

;;; Subscription registry -- maps SID -> subscription with thread-safe access.

(defstruct subscription
  "A NATS subscription."
  (sid 0 :type integer)
  (subject "" :type string)
  (queue-group nil :type (or null string))
  (callback nil :type (or null function))
  (max-msgs nil :type (or null integer))
  (received 0 :type integer)
  (closed-p nil :type boolean))

(defstruct subscription-registry
  "Thread-safe subscription registry."
  (table (make-hash-table :test #'eql) :type hash-table)
  (lock (bt2:make-lock :name "subscription-registry-lock")))

(defun registry-add (registry subscription)
  "Add a subscription to the registry."
  (bt2:with-lock-held ((subscription-registry-lock registry))
    (setf (gethash (subscription-sid subscription)
                   (subscription-registry-table registry))
          subscription))
  subscription)

(defun registry-remove (registry sid)
  "Remove a subscription by SID."
  (bt2:with-lock-held ((subscription-registry-lock registry))
    (remhash sid (subscription-registry-table registry))))

(defun registry-lookup (registry sid)
  "Look up a subscription by SID."
  (bt2:with-lock-held ((subscription-registry-lock registry))
    (gethash sid (subscription-registry-table registry))))

(defun registry-dispatch (registry sid message &key on-error)
  "Dispatch a message to the subscription's callback. Returns T if dispatched.
   Handles max-msgs auto-removal. Callback exceptions are caught and routed
   to ON-ERROR (a function of one argument) if provided, so they never crash
   the reader thread."
  (let ((sub (registry-lookup registry sid)))
    (when (and sub (not (subscription-closed-p sub)))
      (bt2:with-lock-held ((subscription-registry-lock registry))
        (incf (subscription-received sub)))
      ;; Check max-msgs
      (when (and (subscription-max-msgs sub)
                 (>= (subscription-received sub) (subscription-max-msgs sub)))
        (setf (subscription-closed-p sub) t)
        (registry-remove registry sid))
      ;; Call the callback -- isolate user exceptions
      (when (subscription-callback sub)
        (handler-case
            (funcall (subscription-callback sub) message)
          (error (e)
            (when on-error
              (ignore-errors (funcall on-error e))))))
      t)))

(defun registry-all-subscriptions (registry)
  "Return a list of all active subscriptions."
  (let ((result nil))
    (bt2:with-lock-held ((subscription-registry-lock registry))
      (maphash (lambda (k v)
                 (declare (ignore k))
                 (push v result))
               (subscription-registry-table registry)))
    (nreverse result)))

(defun registry-clear (registry)
  "Remove all subscriptions."
  (bt2:with-lock-held ((subscription-registry-lock registry))
    (clrhash (subscription-registry-table registry))))
