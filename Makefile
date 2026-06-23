# Convenience entry points for nova.ci maintenance.

.PHONY: validate
validate: ## Run the full validation harness (YAML, whitespace, skill sync, actionlint)
	@./scripts/validate.sh

.PHONY: help
help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'
