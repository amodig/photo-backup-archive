SHELL := /bin/zsh

REPO_ROOT := $(shell pwd)
AGENTS := $(HOME)/Library/LaunchAgents
AUTO_TPL := launchd/com.cardmirror.auto.plist.tpl
RECON_TPL := launchd/com.cardmirror.reconcile.plist.tpl
AUTO_PLIST := $(AGENTS)/com.cardmirror.auto.plist
RECON_PLIST := $(AGENTS)/com.cardmirror.reconcile.plist

.PHONY: install uninstall reload test plist

plist:
	@mkdir -p $(AGENTS)
	@sed 's#__REPO_ROOT__#$(REPO_ROOT)#g' $(AUTO_TPL) > $(AUTO_PLIST)
	@sed 's#__REPO_ROOT__#$(REPO_ROOT)#g' $(RECON_TPL) > $(RECON_PLIST)

install: plist
	- launchctl unload $(AUTO_PLIST) 2>/dev/null || true
	- launchctl unload $(RECON_PLIST) 2>/dev/null || true
	launchctl load  $(AUTO_PLIST)
	launchctl load  $(RECON_PLIST)
	@echo "Installed launch agents pointing to $(REPO_ROOT)"

uninstall:
	- launchctl unload $(AUTO_PLIST) 2>/dev/null || true
	- launchctl unload $(RECON_PLIST) 2>/dev/null || true
	@rm -f $(AUTO_PLIST) $(RECON_PLIST)
	@echo "Uninstalled launch agents."

reload: install

test:
	@echo "Running DRY_RUN mirror once…"
	DRY_RUN=1 $(REPO_ROOT)/bin/card-mirror.sh || true
	@echo "To reconcile: $(REPO_ROOT)/bin/card-reconcile.sh"
