.DEFAULT_GOAL := help
.PHONY: help setup build up down restart logs shell status secret clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

setup: ## Create .env from the template with a random SESSION_SECRET
	@test -f .env || (cp .env.example .env && sed -i.bak "s/^SESSION_SECRET=.*/SESSION_SECRET=$$(openssl rand -hex 32)/" .env && rm -f .env.bak && echo "Created .env - now set LOGIN_PASSWORD in it.")

build: ## Build the image from source
	docker compose build

up: ## Build (if needed) and start in the background
	docker compose up -d --build

down: ## Stop and remove the container (data volume is kept)
	docker compose down

restart: ## Restart the container
	docker compose restart

logs: ## Follow container logs
	docker compose logs -f --tail=100

shell: ## Open a shell inside the container
	docker compose exec brave bash

status: ## Show container status and health
	docker compose ps

secret: ## Print a random 64-char secret
	@openssl rand -hex 32

clean: ## Stop and DELETE all data including the browser profile
	docker compose down -v --rmi local
