;;; t/package.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Anthony Green <green@moxielogic.com>

(defpackage #:cl-nats/tests
  (:documentation "Tests for cl-nats.")
  (:use #:cl #:parachute)
  (:local-nicknames (#:nats #:cl-nats))
  (:export #:run-tests))

(in-package #:cl-nats/tests)

;; run-tests is defined in integration-tests.lisp (loaded last)
;; so it can reference the shared server harness.
