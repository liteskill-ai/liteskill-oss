# Hello World Tutorial

Welcome! This tutorial gets you up and going with LiteSkill.

## Docker Compose

The fastest way to get up and running is with Docker Compose. Ensure it's installed on your system and then run the following:

```bash
git clone https://github.com/liteskill-ai/liteskill-oss.git && cd liteskill-oss
```

Before starting the app, generate the required secrets:

```bash
export SECRET_KEY_BASE=$(openssl rand -base64 64)
export ENCRYPTION_KEY=$(openssl rand -base64 32)
```

Then start everything:

```bash
docker compose up
```

This starts a PostgreSQL 16 database with pgvector and the Liteskill application. The app container uses host networking so it can reach the database on `localhost`.

## Admin Setup

Open a browser and navigate to [http://localhost:4000/](http://localhost:4000/) and follow the setup instructions.

For testing purposes, we recommend using [OpenRouter](https://openrouter.ai/) as your model provider.
For model selection, we recommend [Claude Sonnet](https://openrouter.ai/anthropic/claude-sonnet-4.5) for inference and [OpenAI: Text Embedding 3 Small](openai/text-embedding-3-small) for embeddings.

## Your First Conversation

1. Navigate back to the main page by clicking `Chat` in the sidebar.
1. Click the "+" icon to the right of "Conversations" in the top left corner of the screen.
1. Type a message and hit Enter!

You should see the LLM stream its response in real-time. Congratulations — you've got Liteskill running!
