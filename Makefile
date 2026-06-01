# Claude Code Sandbox — dev helpers.
IMAGE ?= cc-sandbox:dev

.PHONY: build test lint run clean

build:                ## Build the policy image locally
	docker build -t $(IMAGE) ./image

test: build           ## Build, then run the security harness (no Claude quota used)
	./test/security-harness.sh $(IMAGE)

lint:                 ## Shellcheck the scripts (if installed)
	@command -v shellcheck >/dev/null && shellcheck bin/cc-sandbox install.sh image/*.sh || echo "shellcheck not installed; skipping"

run: build            ## Launch the sandbox in the current directory using the local image
	CC_SANDBOX_IMAGE=$(IMAGE) ./bin/cc-sandbox

clean:                ## Remove local image and dangling per-project volumes
	-docker rmi $(IMAGE)
	-docker volume ls -q --filter name=cc-cache- | xargs -r docker volume rm
	-docker volume ls -q --filter name=cc-session- | xargs -r docker volume rm
