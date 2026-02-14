;;; t/unit-tests.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Anthony Green <green@moxielogic.com>

(in-package #:cl-nats/tests)

;;; Unit tests: protocol, headers, util -- no server needed.

(define-test cl-nats-suite)

;;; --- Utility tests ---

(define-test util-tests :parent cl-nats-suite)

(define-test url-parsing :parent util-tests
  (multiple-value-bind (host port tls-p)
      (cl-nats::parse-nats-url "nats://localhost:4222")
    (is string= "localhost" host)
    (is = 4222 port)
    (false tls-p))
  (multiple-value-bind (host port tls-p)
      (cl-nats::parse-nats-url "tls://example.com:9222")
    (is string= "example.com" host)
    (is = 9222 port)
    (true tls-p))
  ;; Default port
  (multiple-value-bind (host port tls-p)
      (cl-nats::parse-nats-url "nats://myhost")
    (is string= "myhost" host)
    (is = 4222 port)
    (false tls-p))
  ;; Bare host:port
  (multiple-value-bind (host port tls-p)
      (cl-nats::parse-nats-url "10.0.0.1:5555")
    (is string= "10.0.0.1" host)
    (is = 5555 port)
    (false tls-p))
  ;; Empty host defaults
  (multiple-value-bind (host port tls-p)
      (cl-nats::parse-nats-url "nats://:4222")
    (is string= "127.0.0.1" host)
    (is = 4222 port)
    (false tls-p)))

(define-test uid-generation :parent util-tests
  (let ((uid1 (cl-nats::generate-uid))
        (uid2 (cl-nats::generate-uid)))
    (is = 22 (length uid1))
    (is = 22 (length uid2))
    (isnt string= uid1 uid2)))

(define-test sid-generation :parent util-tests
  (let ((s1 (cl-nats::next-sid))
        (s2 (cl-nats::next-sid)))
    (true (integerp s1))
    (true (integerp s2))
    (true (> s2 s1))))

(define-test inbox-generation :parent util-tests
  (let ((inbox (cl-nats::generate-inbox)))
    (true (cl-nats::starts-with-p "_INBOX." inbox))
    (is = (+ 7 22) (length inbox))))

(define-test string-octets-roundtrip :parent util-tests
  (let* ((original "Hello, NATS! Unicode: \u00e9\u00e8\u00ea")
         (octets (cl-nats::string-to-octets original))
         (back (cl-nats::octets-to-string octets)))
    (is string= original back)))

;;; --- Protocol tests ---

(define-test protocol-tests :parent cl-nats-suite)

(define-test format-pub-test :parent protocol-tests
  (let ((payload (cl-nats::string-to-octets "hello")))
    (multiple-value-bind (header pay)
        (cl-nats::format-pub "test.subject" payload)
      (declare (ignore pay))
      (true (search "PUB test.subject 5" header))))
  ;; With reply-to
  (let ((payload (cl-nats::string-to-octets "data")))
    (multiple-value-bind (header pay)
        (cl-nats::format-pub "test.sub" payload :reply-to "reply.here")
      (declare (ignore pay))
      (true (search "PUB test.sub reply.here 4" header)))))

(define-test format-sub-test :parent protocol-tests
  (let ((cmd (cl-nats::format-sub "foo.bar" 42)))
    (true (search "SUB foo.bar 42" cmd)))
  ;; With queue group
  (let ((cmd (cl-nats::format-sub "foo.bar" 42 :queue-group "workers")))
    (true (search "SUB foo.bar workers 42" cmd))))

(define-test format-unsub-test :parent protocol-tests
  (let ((cmd (cl-nats::format-unsub 42)))
    (true (search "UNSUB 42" cmd)))
  ;; With max-msgs
  (let ((cmd (cl-nats::format-unsub 42 :max-msgs 10)))
    (true (search "UNSUB 42 10" cmd))))

(define-test format-ping-pong :parent protocol-tests
  (true (search "PING" (cl-nats::format-ping)))
  (true (search "PONG" (cl-nats::format-pong))))

(define-test format-hpub-test :parent protocol-tests
  (let ((payload (cl-nats::string-to-octets "body"))
        (hdr-octets (cl-nats::string-to-octets "NATS/1.0\r\nX-Foo: bar\r\n\r\n")))
    (multiple-value-bind (header ho po)
        (cl-nats::format-hpub "subj" payload hdr-octets)
      (declare (ignore ho po))
      (true (search "HPUB subj" header))
      ;; Header should contain header-bytes and total-bytes
      (true (search (princ-to-string (length hdr-octets)) header)))))

(define-test parse-server-op-test :parent protocol-tests
  ;; PING
  (multiple-value-bind (op data) (cl-nats::parse-server-op "PING")
    (is eq :ping op)
    (is eq nil data))
  ;; PONG
  (multiple-value-bind (op data) (cl-nats::parse-server-op "PONG")
    (is eq :pong op)
    (is eq nil data))
  ;; +OK
  (multiple-value-bind (op data) (cl-nats::parse-server-op "+OK")
    (is eq :ok op)
    (is eq nil data))
  ;; -ERR
  (multiple-value-bind (op data) (cl-nats::parse-server-op "-ERR 'Authorization Violation'")
    (is eq :err op)
    (is string= "Authorization Violation" data))
  ;; INFO
  (multiple-value-bind (op data)
      (cl-nats::parse-server-op "INFO {\"server_id\":\"test\"}")
    (is eq :info op)
    (is string= "{\"server_id\":\"test\"}" data)))

(define-test parse-msg-line-test :parent protocol-tests
  ;; Without reply-to
  (let ((parsed (cl-nats::parse-msg-line "MSG foo.bar 1 11")))
    (is string= "foo.bar" (cl-nats::parsed-msg-subject parsed))
    (is = 1 (cl-nats::parsed-msg-sid parsed))
    (is eq nil (cl-nats::parsed-msg-reply-to parsed))
    (is = 11 (cl-nats::parsed-msg-byte-count parsed)))
  ;; With reply-to
  (let ((parsed (cl-nats::parse-msg-line "MSG foo.bar 1 reply.to 11")))
    (is string= "foo.bar" (cl-nats::parsed-msg-subject parsed))
    (is = 1 (cl-nats::parsed-msg-sid parsed))
    (is string= "reply.to" (cl-nats::parsed-msg-reply-to parsed))
    (is = 11 (cl-nats::parsed-msg-byte-count parsed))))

(define-test parse-hmsg-line-test :parent protocol-tests
  ;; Without reply-to
  (let ((parsed (cl-nats::parse-hmsg-line "HMSG foo.bar 1 22 33")))
    (is string= "foo.bar" (cl-nats::parsed-hmsg-subject parsed))
    (is = 1 (cl-nats::parsed-hmsg-sid parsed))
    (is eq nil (cl-nats::parsed-hmsg-reply-to parsed))
    (is = 22 (cl-nats::parsed-hmsg-header-bytes parsed))
    (is = 33 (cl-nats::parsed-hmsg-total-bytes parsed)))
  ;; With reply-to
  (let ((parsed (cl-nats::parse-hmsg-line "HMSG foo.bar 1 reply.to 22 33")))
    (is string= "reply.to" (cl-nats::parsed-hmsg-reply-to parsed))))

(define-test parse-info-json-test :parent protocol-tests
  (let ((info (cl-nats::parse-info-json
               "{\"server_id\":\"abc\",\"version\":\"2.10.0\",\"max_payload\":1048576,\"headers\":true}")))
    (is string= "abc" (cl-nats::server-info-server-id info))
    (is string= "2.10.0" (cl-nats::server-info-version info))
    (is = 1048576 (cl-nats::server-info-max-payload info))
    (is eq t (cl-nats::server-info-headers info))))

(define-test parse-server-op-unknown :parent protocol-tests
  (fail (cl-nats::parse-server-op "GARBAGE foo bar") cl-nats:nats-protocol-error))

;;; --- Header tests ---

(define-test header-tests :parent cl-nats-suite)

(define-test header-serialize-roundtrip :parent header-tests
  (let* ((headers '(("X-Trace-Id" . ("abc123"))
                    ("X-Priority" . ("high"))))
         (octets (cl-nats::serialize-headers headers))
         (text (cl-nats::octets-to-string octets)))
    ;; Should contain version line
    (true (search "NATS/1.0" text))
    ;; Should contain headers
    (true (search "X-Trace-Id: abc123" text))
    (true (search "X-Priority: high" text))
    ;; Parse back
    (multiple-value-bind (parsed-headers status status-text)
        (cl-nats::parse-headers octets)
      (is eq nil status)
      (is eq nil status-text)
      (is = 2 (length parsed-headers))
      (is string= "abc123" (second (assoc "X-Trace-Id" parsed-headers :test #'string-equal)))
      (is string= "high" (second (assoc "X-Priority" parsed-headers :test #'string-equal))))))

(define-test header-with-status :parent header-tests
  (let ((octets (cl-nats::serialize-headers '(("X-Foo" . ("bar"))) 503 "No Responders")))
    (multiple-value-bind (hdrs status status-text)
        (cl-nats::parse-headers octets)
      (is = 503 status)
      (is string= "No Responders" status-text)
      (is = 1 (length hdrs)))))

(define-test header-multi-value :parent header-tests
  (let* ((headers '(("Accept" . ("text/plain" "application/json"))))
         (octets (cl-nats::serialize-headers headers)))
    (multiple-value-bind (parsed status)
        (cl-nats::parse-headers octets)
      (declare (ignore status))
      (let ((accept-vals (rest (assoc "Accept" parsed :test #'string-equal))))
        (is = 2 (length accept-vals))
        (is string= "text/plain" (first accept-vals))
        (is string= "application/json" (second accept-vals))))))

(define-test header-empty :parent header-tests
  (let ((octets (cl-nats::serialize-headers nil)))
    (multiple-value-bind (hdrs status)
        (cl-nats::parse-headers octets)
      (is eq nil status)
      (is = 0 (length hdrs)))))

;;; --- Subscription registry tests ---

(define-test subscription-tests :parent cl-nats-suite)

(define-test registry-add-lookup-remove :parent subscription-tests
  (let ((reg (cl-nats::make-subscription-registry))
        (sub (cl-nats::make-subscription :sid 100 :subject "test" :callback nil)))
    (cl-nats::registry-add reg sub)
    (true (cl-nats::registry-lookup reg 100))
    (is eq sub (cl-nats::registry-lookup reg 100))
    (cl-nats::registry-remove reg 100)
    (false (cl-nats::registry-lookup reg 100))))

(define-test registry-dispatch-test :parent subscription-tests
  (let ((reg (cl-nats::make-subscription-registry))
        (received nil))
    (let ((sub (cl-nats::make-subscription
                :sid 200 :subject "test"
                :callback (lambda (msg)
                            (push (nats:message-data-string msg) received)))))
      (cl-nats::registry-add reg sub)
      (let ((msg (cl-nats::make-message
                  :subject "test" :sid 200
                  :data (cl-nats::string-to-octets "hello"))))
        (true (cl-nats::registry-dispatch reg 200 msg))
        (is = 1 (length received))
        (is string= "hello" (first received))))))

(define-test registry-max-msgs :parent subscription-tests
  (let ((reg (cl-nats::make-subscription-registry))
        (count 0))
    (let ((sub (cl-nats::make-subscription
                :sid 300 :subject "test"
                :callback (lambda (msg) (declare (ignore msg)) (incf count))
                :max-msgs 2)))
      (cl-nats::registry-add reg sub)
      (let ((msg (cl-nats::make-message :subject "test" :sid 300
                                        :data (cl-nats::string-to-octets ""))))
        (cl-nats::registry-dispatch reg 300 msg)
        (cl-nats::registry-dispatch reg 300 msg)
        ;; After 2 messages, subscription should be removed
        (false (cl-nats::registry-lookup reg 300))
        (is = 2 count)))))

(define-test registry-dispatch-callback-isolation :parent subscription-tests
  ;; A callback that throws should not prevent dispatch from returning T,
  ;; and the error should be routed to on-error.
  (let ((reg (cl-nats::make-subscription-registry))
        (error-caught nil))
    (let ((sub (cl-nats::make-subscription
                 :sid 400 :subject "test"
                 :callback (lambda (msg)
                             (declare (ignore msg))
                             (error "deliberate explosion")))))
      (cl-nats::registry-add reg sub)
      (let ((msg (cl-nats::make-message :subject "test" :sid 400
                                        :data (cl-nats::string-to-octets "boom"))))
        ;; Dispatch should return T (message was delivered to callback)
        (true (cl-nats::registry-dispatch reg 400 msg
                :on-error (lambda (e)
                            (setf error-caught (princ-to-string e)))))
        ;; on-error should have been called
        (true error-caught)
        (true (search "deliberate explosion" error-caught))))))

(define-test registry-dispatch-no-on-error :parent subscription-tests
  ;; Even without on-error, a throwing callback must not escape.
  (let ((reg (cl-nats::make-subscription-registry)))
    (let ((sub (cl-nats::make-subscription
                 :sid 500 :subject "test"
                 :callback (lambda (msg)
                             (declare (ignore msg))
                             (error "uncaught boom")))))
      (cl-nats::registry-add reg sub)
      (let ((msg (cl-nats::make-message :subject "test" :sid 500
                                        :data (cl-nats::string-to-octets "data"))))
        ;; Should not signal -- error is swallowed
        (true (cl-nats::registry-dispatch reg 500 msg))))))

(define-test registry-all-subscriptions :parent subscription-tests
  (let ((reg (cl-nats::make-subscription-registry)))
    (cl-nats::registry-add reg (cl-nats::make-subscription :sid 1 :subject "a" :callback nil))
    (cl-nats::registry-add reg (cl-nats::make-subscription :sid 2 :subject "b" :callback nil))
    (cl-nats::registry-add reg (cl-nats::make-subscription :sid 3 :subject "c" :callback nil))
    (is = 3 (length (cl-nats::registry-all-subscriptions reg)))
    (cl-nats::registry-clear reg)
    (is = 0 (length (cl-nats::registry-all-subscriptions reg)))))
