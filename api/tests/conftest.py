"""Shared pytest fixtures."""
import os

# Force mock TRIBE before any import of api.* modules picks up settings.
os.environ.setdefault("TRIBE_BACKEND", "mock")
os.environ.setdefault("ANTHROPIC_API_KEY", "")  # force offline proposer in agent
