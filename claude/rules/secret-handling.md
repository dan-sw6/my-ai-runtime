# Secret Handling Rules

## Never Commit
- API keys, tokens, passwords, credentials
- `.env` files with real values
- Private keys or certificates
- Database connection strings with passwords

## Safe Patterns
- Use environment variables for all secrets
- Reference `.env.example` with placeholder values
- Use secret management tools in production

## Detection
- If you notice secrets in code, flag immediately
- Check staged files before committing
- Do not log or print secret values even for debugging
