;;; package.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Anthony Green <green@moxielogic.com>

(defpackage #:cl-nats
  (:use #:cl)
  (:documentation "A full-featured NATS messaging client for Common Lisp.")
  (:export
   ;; Conditions
   #:nats-error
   #:nats-connection-error
   #:nats-timeout-error
   #:nats-protocol-error
   #:nats-server-error
   #:nats-stale-connection
   #:nats-no-responders
   #:nats-max-payload-error

   ;; Client lifecycle
   #:make-client
   #:connect
   #:close-connection
   #:client-status

   ;; Pub/Sub
   #:publish
   #:subscribe
   #:unsubscribe

   ;; Request-Reply
   #:request

   ;; Message accessors
   #:message
   #:message-subject
   #:message-data
   #:message-data-string
   #:message-reply-to
   #:message-headers
   #:message-sid

   ;; Subscription accessors
   #:subscription
   #:subscription-sid
   #:subscription-subject
   #:subscription-queue-group

   ;; Event callbacks
   #:on-disconnect
   #:on-reconnect
   #:on-error
   #:on-close))

(in-package #:cl-nats)
