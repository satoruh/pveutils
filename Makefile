.PHONY: test syntax lint

# 機能テストは Proxmox クラスタが必要なため不可。ここでは静的チェックのみ。
test: syntax lint

syntax:
	@for f in scripts/*.sh scripts/lib/*.sh; do echo "bash -n $$f"; bash -n "$$f"; done
	@echo "bash -n (embedded REMOTE payload)"
	@sed -n "/<<'REMOTE'/,/^REMOTE$$/p" scripts/pve-maintenance.sh | sed '1d;$$d' | bash -n

lint:
	shellcheck -x scripts/*.sh scripts/lib/*.sh
