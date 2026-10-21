# Operator checks for a self-hosted install of Kortix, the open-source AI Operating System.
DOMAIN ?=
INSTANCE ?= default

.PHONY: help preflight doctor signup backup verify

help:
	@echo "make preflight DOMAIN=kortix.example.com   # before init"
	@echo "make doctor                                # decode kortix self-host doctor"
	@echo "make signup DOMAIN=kortix.example.com      # can a stranger create an account?"
	@echo "make backup                                # stop, archive, verify, start"
	@echo "make verify DOMAIN=kortix.example.com      # the weekly pass"

preflight:
	@./bin/preflight.sh $(DOMAIN)

doctor:
	@./bin/doctor.sh $(INSTANCE)

signup:
	@if [ -n "$(DOMAIN)" ]; then ./bin/check-signup.sh https://$(DOMAIN); else ./bin/check-signup.sh --instance $(INSTANCE); fi

backup:
	@./bin/backup.sh $(INSTANCE)

verify:
	@if [ -n "$(DOMAIN)" ]; then ./bin/verify-all.sh https://$(DOMAIN); else ./bin/verify-all.sh --instance $(INSTANCE); fi
