;;; cl-nats.asd
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Anthony Green <green@moxielogic.com>

(asdf:defsystem "cl-nats"
  :description "A full-featured NATS messaging client for Common Lisp."
  :author      "Anthony Green <green@moxielogic.com>"
  :license     "MIT"
  :version     "0.1.0"
  :depends-on  ("usocket"
                "flexi-streams"
                "bordeaux-threads"
                "pure-tls"
                "cl-cancel"
                "com.inuoe.jzon"
                "cl-ppcre")
  :serial t
  :components ((:file "src/package")
               (:file "src/conditions")
               (:file "src/util")
               (:file "src/headers")
               (:file "src/protocol")
               (:file "src/transport")
               (:file "src/subscription")
               (:file "src/connection")
               (:file "src/client")))

(asdf:defsystem "cl-nats/tests"
  :description "Tests for cl-nats."
  :author      "Anthony Green <green@moxielogic.com>"
  :license     "MIT"
  :depends-on  ("cl-nats" "parachute" "bordeaux-threads")
  :serial t
  :components ((:file "t/package")
               (:file "t/server-harness")
               (:file "t/unit-tests")
               (:file "t/integration-tests")))
