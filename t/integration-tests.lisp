;;; t/integration-tests.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Anthony Green <green@moxielogic.com>

(in-package #:cl-nats/tests)

;;; Integration tests: start nats-server, run real client scenarios.
;;;
;;; A single shared server is used for most tests to avoid the overhead
;;; of starting/stopping nats-server for every test.  Only the reconnect
;;; test manages its own server lifecycle.

(define-test integration-tests :parent cl-nats-suite)

;;; Shared server -- started by run-integration-tests, stopped on exit.

(defvar *shared-server* nil
  "Shared nats-server for integration tests.")

(defun shared-server-url ()
  "Return the URL of the shared test server."
  (server-url *shared-server*))

(defmacro with-shared-client ((client-var) &body body)
  "Execute BODY with a connected NATS client on the shared server."
  `(let ((,client-var (nats:make-client :servers (list (shared-server-url))
                                        :reconnect-allowed nil
                                        :ping-interval 0)))
     (unwind-protect
          (progn
            (nats:connect ,client-var)
            ,@body)
       (ignore-errors (nats:close-connection ,client-var)))))

;;; --- Basic connection ---

(define-test connect-and-close :parent integration-tests
  (let ((client (nats:make-client :servers (list (shared-server-url))
                                  :name "test-connect"
                                  :reconnect-allowed nil
                                  :ping-interval 0)))
    (nats:connect client)
    (is eq :connected (nats:client-status client))
    (nats:close-connection client)
    (is eq :closed (nats:client-status client))))

(define-test connect-failure :parent integration-tests
  ;; Connecting to a port with no server should signal error
  (let ((client (nats:make-client :servers '("nats://127.0.0.1:19999")
                                  :reconnect-allowed nil
                                  :ping-interval 0)))
    (fail (nats:connect client) nats:nats-connection-error)))

;;; --- Pub/Sub between two clients ---

(define-test two-client-pubsub :parent integration-tests
  (with-shared-client (subscriber)
    (with-shared-client (publisher)
      (let ((received nil)
            (lock (bt2:make-lock :name "test-lock")))
        ;; Subscribe on client 1
        (nats:subscribe subscriber "test.greeting"
          (lambda (msg)
            (bt2:with-lock-held (lock)
              (push (nats:message-data-string msg) received))))
        ;; Give subscription time to register on server
        (sleep 0.2)
        ;; Publish from client 2
        (nats:publish publisher "test.greeting" "Hello from publisher!")
        ;; Wait for delivery
        (true (wait-for (lambda ()
                          (bt2:with-lock-held (lock)
                            (= 1 (length received))))))
        (bt2:with-lock-held (lock)
          (is string= "Hello from publisher!" (first received)))))))

(define-test wildcard-subscription :parent integration-tests
  (with-shared-client (sub-client)
    (with-shared-client (pub-client)
      (let ((received nil)
            (lock (bt2:make-lock :name "test-lock")))
        ;; Subscribe to wildcard
        (nats:subscribe sub-client "events.>"
          (lambda (msg)
            (bt2:with-lock-held (lock)
              (push (nats:message-subject msg) received))))
        (sleep 0.2)
        ;; Publish to various sub-subjects
        (nats:publish pub-client "events.user.login" "data1")
        (nats:publish pub-client "events.user.logout" "data2")
        (nats:publish pub-client "events.system.startup" "data3")
        ;; Wait for all three
        (true (wait-for (lambda ()
                          (bt2:with-lock-held (lock)
                            (= 3 (length received))))))
        (bt2:with-lock-held (lock)
          (true (member "events.user.login" received :test #'string=))
          (true (member "events.user.logout" received :test #'string=))
          (true (member "events.system.startup" received :test #'string=)))))))

(define-test multiple-subscribers :parent integration-tests
  (with-shared-client (client-a)
    (with-shared-client (client-b)
      (with-shared-client (pub-client)
        (let ((received-a nil)
              (received-b nil)
              (lock (bt2:make-lock :name "test-lock")))
          ;; Both subscribe to the same subject
          (nats:subscribe client-a "shared.topic"
            (lambda (msg)
              (bt2:with-lock-held (lock)
                (push (nats:message-data-string msg) received-a))))
          (nats:subscribe client-b "shared.topic"
            (lambda (msg)
              (bt2:with-lock-held (lock)
                (push (nats:message-data-string msg) received-b))))
          (sleep 0.2)
          ;; Publish once
          (nats:publish pub-client "shared.topic" "broadcast message")
          ;; Both should receive
          (true (wait-for (lambda ()
                            (bt2:with-lock-held (lock)
                              (and (= 1 (length received-a))
                                   (= 1 (length received-b)))))))
          (bt2:with-lock-held (lock)
            (is string= "broadcast message" (first received-a))
            (is string= "broadcast message" (first received-b))))))))

;;; --- Unsubscribe ---

(define-test unsubscribe-test :parent integration-tests
  (with-shared-client (client)
    (let ((count 0)
          (lock (bt2:make-lock :name "test-lock")))
      (let ((sub (nats:subscribe client "unsub.test"
                   (lambda (msg)
                     (declare (ignore msg))
                     (bt2:with-lock-held (lock) (incf count))))))
        (sleep 0.1)
        (nats:publish client "unsub.test" "msg1")
        (true (wait-for (lambda () (bt2:with-lock-held (lock) (= 1 count)))))
        ;; Unsubscribe
        (nats:unsubscribe client sub)
        (sleep 0.1)
        ;; This should NOT be received
        (nats:publish client "unsub.test" "msg2")
        (sleep 0.5)
        (bt2:with-lock-held (lock)
          (is = 1 count))))))

(define-test unsubscribe-max-msgs :parent integration-tests
  (with-shared-client (client)
    (let ((received nil)
          (lock (bt2:make-lock :name "test-lock")))
      (let ((sub (nats:subscribe client "maxmsg.test"
                   (lambda (msg)
                     (bt2:with-lock-held (lock)
                       (push (nats:message-data-string msg) received))))))
        ;; Unsub after 2 messages
        (nats:unsubscribe client sub :max-msgs 2)
        (sleep 0.1)
        ;; Send 5 messages
        (dotimes (i 5)
          (nats:publish client "maxmsg.test" (format nil "msg-~d" i)))
        (sleep 0.5)
        ;; Should only receive 2
        (bt2:with-lock-held (lock)
          (is = 2 (length received)))))))

;;; --- Request-Reply ---

(define-test request-reply :parent integration-tests
  (with-shared-client (responder)
    (with-shared-client (requester)
      ;; Set up a responder service
      (nats:subscribe responder "echo.service"
        (lambda (msg)
          (let ((reply-to (nats:message-reply-to msg)))
            (when reply-to
              (nats:publish responder reply-to
                (concatenate 'string "echo: "
                             (nats:message-data-string msg)))))))
      (sleep 0.2)
      ;; Send request from another client
      (let ((reply (nats:request requester "echo.service" "hello" :timeout 5)))
        (is string= "echo: hello" (nats:message-data-string reply))))))

(define-test request-no-responders :parent integration-tests
  ;; With no_responders enabled, server sends 503 immediately
  (with-shared-client (client)
    (fail (nats:request client "nobody.home" "data" :timeout 5)
          nats:nats-no-responders)))

(define-test request-timeout :parent integration-tests
  ;; Subscribing to the subject (but not replying) should cause a timeout
  (with-shared-client (client)
    ;; Subscribe but never reply -- request should time out
    (nats:subscribe client "slow.service"
      (lambda (msg) (declare (ignore msg))))
    (sleep 0.1)
    (fail (nats:request client "slow.service" "data" :timeout 1)
          nats:nats-timeout-error)))

(define-test request-reply-multiple :parent integration-tests
  (with-shared-client (responder)
    (with-shared-client (requester)
      ;; Responder echoes with uppercase
      (nats:subscribe responder "upper.service"
        (lambda (msg)
          (when (nats:message-reply-to msg)
            (nats:publish responder (nats:message-reply-to msg)
              (string-upcase (nats:message-data-string msg))))))
      (sleep 0.2)
      ;; Multiple sequential requests
      (let ((r1 (nats:request requester "upper.service" "hello" :timeout 5))
            (r2 (nats:request requester "upper.service" "world" :timeout 5))
            (r3 (nats:request requester "upper.service" "nats" :timeout 5)))
        (is string= "HELLO" (nats:message-data-string r1))
        (is string= "WORLD" (nats:message-data-string r2))
        (is string= "NATS" (nats:message-data-string r3))))))

;;; --- Binary data ---

(define-test binary-payload :parent integration-tests
  (with-shared-client (client)
    (let ((received-data nil)
          (lock (bt2:make-lock :name "test-lock"))
          (original (make-array 256 :element-type '(unsigned-byte 8)
                                    :initial-contents (loop for i below 256 collect i))))
      (nats:subscribe client "binary.test"
        (lambda (msg)
          (bt2:with-lock-held (lock)
            (setf received-data (nats:message-data msg)))))
      (sleep 0.1)
      (nats:publish client "binary.test" original)
      (true (wait-for (lambda () (bt2:with-lock-held (lock) received-data))))
      (bt2:with-lock-held (lock)
        (is = (length original) (length received-data))
        (true (equalp original received-data))))))

;;; --- Headers ---

(define-test publish-with-headers :parent integration-tests
  (with-shared-client (sub-client)
    (with-shared-client (pub-client)
      (let ((received-msg nil)
            (lock (bt2:make-lock :name "test-lock")))
        (nats:subscribe sub-client "hdr.test"
          (lambda (msg)
            (bt2:with-lock-held (lock)
              (setf received-msg msg))))
        (sleep 0.2)
        ;; Publish with headers
        (nats:publish pub-client "hdr.test" "payload"
          :headers '(("X-Request-Id" . ("req-42"))
                     ("X-Priority" . ("high"))))
        (true (wait-for (lambda () (bt2:with-lock-held (lock) received-msg))))
        (bt2:with-lock-held (lock)
          (is string= "payload" (nats:message-data-string received-msg))
          (let ((hdrs (nats:message-headers received-msg)))
            (true hdrs)
            (is string= "req-42"
                (second (assoc "X-Request-Id" hdrs :test #'string-equal)))
            (is string= "high"
                (second (assoc "X-Priority" hdrs :test #'string-equal)))))))))

;;; --- Queue groups ---

(define-test queue-group-load-balance :parent integration-tests
  (with-shared-client (worker-a)
    (with-shared-client (worker-b)
      (with-shared-client (pub-client)
        (let ((count-a 0)
              (count-b 0)
              (lock (bt2:make-lock :name "test-lock")))
          ;; Both subscribe with same queue group
          (nats:subscribe worker-a "work.queue"
            (lambda (msg)
              (declare (ignore msg))
              (bt2:with-lock-held (lock) (incf count-a)))
            :queue-group "workers")
          (nats:subscribe worker-b "work.queue"
            (lambda (msg)
              (declare (ignore msg))
              (bt2:with-lock-held (lock) (incf count-b)))
            :queue-group "workers")
          (sleep 0.2)
          ;; Send a burst of messages
          (dotimes (i 20)
            (nats:publish pub-client "work.queue" (format nil "job-~d" i)))
          ;; Wait for all to be consumed
          (true (wait-for (lambda ()
                            (bt2:with-lock-held (lock)
                              (= 20 (+ count-a count-b))))
                          :timeout 5))
          ;; Total should be 20 -- each message delivered to exactly one worker
          (bt2:with-lock-held (lock)
            (is = 20 (+ count-a count-b))))))))

;;; --- Event callbacks ---

(define-test event-callbacks :parent integration-tests
  (let ((closed nil)
        (lock (bt2:make-lock :name "test-lock")))
    (let ((client (nats:make-client :servers (list (shared-server-url))
                                    :reconnect-allowed nil
                                    :ping-interval 0)))
      (setf (nats:on-close client)
            (lambda ()
              (bt2:with-lock-held (lock) (setf closed t))))
      (nats:connect client)
      (nats:close-connection client)
      (sleep 0.2)
      (bt2:with-lock-held (lock)
        (true closed)))))

;;; --- Concurrent publishers ---

(define-test concurrent-publishers :parent integration-tests
  (with-shared-client (subscriber)
    (let ((total-received 0)
          (lock (bt2:make-lock :name "test-lock"))
          (num-publishers 3)
          (msgs-per-publisher 10))
      ;; Subscribe
      (nats:subscribe subscriber "concurrent.test"
        (lambda (msg)
          (declare (ignore msg))
          (bt2:with-lock-held (lock) (incf total-received))))
      (sleep 0.2)
      ;; Launch multiple publisher clients in threads
      (let ((threads nil))
        (dotimes (p num-publishers)
          (push (bt2:make-thread
                 (lambda ()
                   (let ((pub (nats:make-client :servers (list (shared-server-url))
                                                :reconnect-allowed nil
                                                :ping-interval 0)))
                     (nats:connect pub)
                     (unwind-protect
                          (dotimes (i msgs-per-publisher)
                            (nats:publish pub "concurrent.test"
                              (format nil "pub-~d-msg-~d" p i)))
                       (ignore-errors (nats:close-connection pub)))))
                 :name (format nil "publisher-~d" p))
                threads))
        ;; Wait for all publisher threads to finish
        (mapc #'bt2:join-thread threads)
        ;; Wait for all messages
        (true (wait-for (lambda ()
                          (bt2:with-lock-held (lock)
                            (= (* num-publishers msgs-per-publisher)
                               total-received)))
                        :timeout 10))
        (bt2:with-lock-held (lock)
          (is = (* num-publishers msgs-per-publisher) total-received))))))

;;; --- Callback exception isolation ---

(define-test callback-exception-no-disconnect :parent integration-tests
  ;; A user callback that signals an error must NOT disconnect the client
  (with-shared-client (client)
    (let ((error-caught nil)
          (good-received nil)
          (lock (bt2:make-lock :name "test-lock")))
      ;; Route errors to on-error callback
      (setf (nats:on-error client)
            (lambda (e)
              (declare (ignore e))
              (bt2:with-lock-held (lock) (setf error-caught t))))
      ;; Subscribe with a callback that throws
      (nats:subscribe client "explode.test"
        (lambda (msg)
          (declare (ignore msg))
          (error "deliberate callback explosion")))
      ;; Subscribe with a well-behaved callback
      (nats:subscribe client "good.test"
        (lambda (msg)
          (bt2:with-lock-held (lock)
            (setf good-received (nats:message-data-string msg)))))
      (sleep 0.2)
      ;; Trigger the exploding callback
      (nats:publish client "explode.test" "boom")
      (sleep 0.3)
      ;; Client should still be connected
      (is eq :connected (nats:client-status client))
      ;; on-error should have been called
      (bt2:with-lock-held (lock)
        (true error-caught))
      ;; And subsequent messages on other subscriptions should still work
      (nats:publish client "good.test" "still alive")
      (true (wait-for (lambda ()
                        (bt2:with-lock-held (lock) good-received))))
      (bt2:with-lock-held (lock)
        (is string= "still alive" good-received)))))

;;; --- Empty payload ---

(define-test empty-payload :parent integration-tests
  (with-shared-client (client)
    (let ((received-msg nil)
          (lock (bt2:make-lock :name "test-lock")))
      (nats:subscribe client "empty.test"
        (lambda (msg)
          (bt2:with-lock-held (lock)
            (setf received-msg msg))))
      (sleep 0.1)
      (nats:publish client "empty.test" "")
      (true (wait-for (lambda () (bt2:with-lock-held (lock) received-msg))))
      (bt2:with-lock-held (lock)
        (is = 0 (length (nats:message-data received-msg)))
        (is string= "" (nats:message-data-string received-msg))))))

;;; --- Reconnection (needs its own server lifecycle, so it starts/stops
;;;     its own nats-server independently of the shared one) ---

(define-test reconnect-after-server-restart :parent integration-tests
  (let* ((port (find-free-port))
         (server (start-nats-server :port port))
         (reconnected nil)
         (lock (bt2:make-lock :name "test-lock")))
    (unwind-protect
         (let ((client (nats:make-client :servers (list (format nil "nats://127.0.0.1:~a" port))
                                         :name "test-reconnect"
                                         :reconnect-allowed t
                                         :reconnect-wait 0.5
                                         :reconnect-max-wait 2
                                         :ping-interval 0)))
           (setf (nats:on-reconnect client)
                 (lambda ()
                   (bt2:with-lock-held (lock)
                     (setf reconnected t))))
           (nats:connect client)
           (is eq :connected (nats:client-status client))
           ;; Subscribe before server goes down
           (let ((received nil))
             (nats:subscribe client "recon.test"
               (lambda (msg)
                 (bt2:with-lock-held (lock)
                   (push (nats:message-data-string msg) received))))
             (sleep 0.2)
             ;; Kill server
             (stop-nats-server server)
             (sleep 1)
             ;; Restart server on same port
             (setf server (start-nats-server :port port))
             ;; Wait for reconnect
             (true (wait-for (lambda ()
                               (bt2:with-lock-held (lock) reconnected))
                             :timeout 15))
             (is eq :connected (nats:client-status client))
             ;; Subscription should have been replayed -- publish and verify
             (sleep 0.3)
             (nats:publish client "recon.test" "after reconnect")
             (true (wait-for (lambda ()
                               (bt2:with-lock-held (lock)
                                 (= 1 (length received))))
                             :timeout 5))
             (bt2:with-lock-held (lock)
               (is string= "after reconnect" (first received))))
           (ignore-errors (nats:close-connection client)))
      (stop-nats-server server))))

;;; --- Test runner ---

(defun run-tests ()
  "Run the full cl-nats test suite.
   Starts a shared nats-server for integration tests, stops it on exit."
  (setf *shared-server* (start-nats-server))
  (unwind-protect
       (test 'cl-nats-suite :report 'plain)
    (stop-nats-server *shared-server*)
    (setf *shared-server* nil)))
