;;; headers.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Anthony Green <green@moxielogic.com>

(in-package #:cl-nats)

;;; Headers are represented as alists: ((name . (val1 val2 ...)) ...)

(defvar *nats-header-version* "NATS/1.0")

(defun serialize-headers (headers &optional status status-text)
  "Serialize headers alist to NATS header bytes.
   Returns octets. Format: NATS/1.0 [status [text]]\\r\\n{name: value\\r\\n}*\\r\\n"
  (let ((lines (list)))
    ;; Version line
    (if status
        (push (format nil "~a ~a~@[ ~a~]" *nats-header-version* status status-text) lines)
        (push *nats-header-version* lines))
    ;; Header lines
    (dolist (pair headers)
      (let ((name (first pair))
            (values (rest pair)))
        (dolist (val (if (listp values) values (list values)))
          (push (format nil "~a: ~a" name val) lines))))
    ;; Build final string with CRLF
    (let ((result (with-output-to-string (s)
                    (dolist (line (nreverse lines))
                      (write-string line s)
                      (write-string (coerce '(#\Return #\Newline) 'string) s))
                    ;; Terminal CRLF
                    (write-string (coerce '(#\Return #\Newline) 'string) s))))
      (string-to-octets result))))

(defun parse-headers (octets)
  "Parse NATS header octets into (values headers status status-text).
   Headers is alist ((name . (val1 ...)) ...)."
  (let* ((text (octets-to-string octets))
         (lines (cl-ppcre:split "\\r\\n" text))
         (headers nil)
         (status nil)
         (status-text nil))
    ;; Parse version line
    (when lines
      (let ((version-line (pop lines)))
        (multiple-value-bind (match groups)
            (cl-ppcre:scan-to-strings "^NATS/1\\.0(?:\\s+(\\d+))?(?:\\s+(.*))?$" version-line)
          (when match
            (when (aref groups 0)
              (setf status (parse-integer (aref groups 0) :junk-allowed t)))
            (when (aref groups 1)
              (setf status-text (string-trim '(#\Space #\Tab) (aref groups 1)))
              (when (string= status-text "")
                (setf status-text nil)))))))
    ;; Parse header lines
    (dolist (line lines)
      (when (and line (not (string= line "")))
        (let ((colon-pos (position #\: line)))
          (when colon-pos
            (let ((name (string-trim '(#\Space #\Tab) (subseq line 0 colon-pos)))
                  (value (string-trim '(#\Space #\Tab) (subseq line (1+ colon-pos)))))
              (let ((existing (assoc name headers :test #'string-equal)))
                (if existing
                    (nconc (rest existing) (list value))
                    (push (list name value) headers))))))))
    (values (nreverse headers) status status-text)))
