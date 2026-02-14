.PHONY: test lint

test:
	sbcl --non-interactive \
	  --eval '(require :asdf)' \
	  --eval '(push (truename ".") asdf:*central-registry*)' \
	  --eval '(asdf:load-system :cl-nats/tests)' \
	  --eval '(let ((result (cl-nats/tests:run-tests))) (sb-ext:exit :code (if (eql (parachute:status result) :passed) 0 1)))'

lint:
	ocicl lint cl-nats.asd
