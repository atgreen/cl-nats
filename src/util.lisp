;;; util.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Anthony Green <green@moxielogic.com>

(in-package #:cl-nats)

(defvar *sid-counter* (bt2:make-atomic-integer :value 0))

(defun next-sid ()
  "Return the next unique subscription ID as an integer."
  (bt2:atomic-integer-incf *sid-counter*))

(defvar *uid-random-state* (make-random-state t))
(defvar *uid-lock* (bt2:make-lock :name "uid-lock"))

(defvar *base62-chars* "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

(defun generate-uid (&optional (length 22))
  "Generate a random base-62 unique identifier string."
  (let ((result (make-string length)))
    (bt2:with-lock-held (*uid-lock*)
      (dotimes (i length)
        (setf (aref result i)
              (aref *base62-chars* (random 62 *uid-random-state*)))))
    result))

(defvar *inbox-prefix* "_INBOX.")

(defun generate-inbox ()
  "Generate a unique inbox subject for request-reply."
  (concatenate 'string *inbox-prefix* (generate-uid)))

(defun string-to-octets (string)
  "Convert a string to UTF-8 octets."
  (flexi-streams:string-to-octets string :external-format :utf-8))

(defun octets-to-string (octets)
  "Convert UTF-8 octets to a string."
  (flexi-streams:octets-to-string octets :external-format :utf-8))

(defun current-time-ms ()
  "Return current time in milliseconds."
  (let ((time (cl-cancel:get-current-time)))
    (round (* time 1000))))

(defun parse-nats-url (url)
  "Parse a NATS URL (nats://host:port or tls://host:port) into (values host port tls-p).
   Defaults: host=127.0.0.1, port=4222."
  (let* ((url (string-trim '(#\Space #\Tab) url))
         (tls-p nil)
         (rest url))
    (cond
      ((and (>= (length rest) 7)
            (string-equal rest "nats://" :end1 7))
       (setf rest (subseq rest 7)))
      ((and (>= (length rest) 6)
            (string-equal rest "tls://" :end1 6))
       (setf rest (subseq rest 6))
       (setf tls-p t))
      (t nil))
    (let* ((colon-pos (position #\: rest))
           (host (if colon-pos
                     (subseq rest 0 colon-pos)
                     rest))
           (port (if colon-pos
                     (parse-integer (subseq rest (1+ colon-pos)) :junk-allowed t)
                     4222)))
      (when (or (null host) (string= host ""))
        (setf host "127.0.0.1"))
      (when (null port)
        (setf port 4222))
      (values host port tls-p))))
