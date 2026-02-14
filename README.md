# cl-nats

A full-featured [NATS](https://nats.io) messaging client for Common Lisp.

## Features

- **Pub/Sub** -- publish messages and subscribe with callbacks
- **Request-Reply** -- synchronous request with timeout
- **Headers** -- NATS headers support (HPUB/HMSG)
- **TLS 1.3** -- via [pure-tls](https://github.com/atgreen/pure-tls) (no OpenSSL)
- **Auto-Reconnect** -- exponential backoff, server rotation, subscription replay
- **Cluster Discovery** -- automatic discovery of cluster nodes via `connect_urls`
- **Keep-Alive** -- periodic PING/PONG with stale connection detection
- **Cancellation** -- [cl-cancel](https://github.com/atgreen/cl-cancel) for timeouts and clean shutdown

## Installation

Using [ocicl](https://github.com/ocicl/ocicl):

```sh
ocicl install usocket flexi-streams bordeaux-threads pure-tls cl-cancel com.inuoe.jzon cl-ppcre
```

## Quick Start

```lisp
(asdf:load-system :cl-nats)

;; Create and connect
(defvar *client* (cl-nats:make-client :servers '("nats://127.0.0.1:4222")))
(cl-nats:connect *client*)

;; Subscribe
(cl-nats:subscribe *client* "greet.*"
  (lambda (msg)
    (format t "Received on ~a: ~a~%"
            (cl-nats:message-subject msg)
            (cl-nats:message-data-string msg))))

;; Publish
(cl-nats:publish *client* "greet.world" "Hello, NATS!")

;; Request-Reply
(let ((reply (cl-nats:request *client* "service.echo" "ping" :timeout 5)))
  (format t "Reply: ~a~%" (cl-nats:message-data-string reply)))

;; Close
(cl-nats:close-connection *client*)
```

## TLS

Connect with TLS using the `tls://` scheme:

```lisp
(defvar *client* (cl-nats:make-client :servers '("tls://nats.example.com:4222")))
(cl-nats:connect *client*)
```

TLS is also automatically enabled when the server requires it (`tls_required` in INFO).

## Headers

```lisp
;; Publish with headers
(cl-nats:publish *client* "subject" "data"
  :headers '(("X-Trace-Id" . ("abc123"))
             ("X-Priority" . ("high"))))
```

## Event Callbacks

```lisp
(setf (cl-nats:on-disconnect *client*) (lambda () (format t "Disconnected~%")))
(setf (cl-nats:on-reconnect *client*)  (lambda () (format t "Reconnected~%")))
(setf (cl-nats:on-error *client*)      (lambda (err) (format t "Error: ~a~%" err)))
(setf (cl-nats:on-close *client*)      (lambda () (format t "Closed~%")))
```

## Configuration

```lisp
(cl-nats:make-client
  :servers '("nats://host1:4222" "nats://host2:4222")
  :name "my-app"
  :user "admin" :pass "secret"
  :reconnect-allowed t
  :reconnect-wait 2           ; base backoff seconds
  :reconnect-max-wait 60      ; max backoff seconds
  :max-reconnect-attempts -1  ; -1 = unlimited
  :ping-interval 120          ; seconds between pings
  :max-outstanding-pings 2)   ; stale connection threshold
```

## Author and License

`cl-nats` was written by Anthony Green <green@moxielogic.com> and
is distributed under the terms of the MIT license.
