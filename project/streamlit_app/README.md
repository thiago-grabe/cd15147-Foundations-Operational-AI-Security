# Northstar Knowledge Base - Streamlit App

A simple web interface for querying the Northstar Knowledge Base using Amazon Bedrock.

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────────────────────┐
│   Browser   │────▶│  Streamlit  │────▶│      Amazon Bedrock         │
│   (User)    │◀────│    App      │◀────│  Agent → KB → Claude 3.7   │
└─────────────┘     └─────────────┘     └─────────────────────────────┘
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `BEDROCK_AGENT_ID` | Yes | Your Bedrock Agent ID |
| `BEDROCK_AGENT_ALIAS_ID` | No | Agent alias (default: `TSTALIASID` for test) |
| `AWS_REGION` | No | AWS region (default: `us-east-1`) |
| `APP_PASSWORD` | No | Password to access the app (empty = no auth) |
| `AWS_ACCESS_KEY_ID` | * | AWS credentials (if not using IAM role) |
| `AWS_SECRET_ACCESS_KEY` | * | AWS credentials (if not using IAM role) |

*AWS credentials are automatically picked up by boto3 from env vars, `~/.aws/credentials`, or IAM roles.

## Quick Start (Local)

1. **Install dependencies:**
   ```bash
   pip install -r requirements.txt
   ```

2. **Configure environment:**
   ```bash
   cp .env.example .env
   # Edit .env with your values
   ```

3. **Run the app:**
   ```bash
   streamlit run app.py
   ```

4. **Open browser:** http://localhost:8501

## Deployment Options

### EC2 with IAM Role
```bash
# On EC2 with IAM role attached (no AWS keys needed)
export BEDROCK_AGENT_ID="your-agent-id"
export APP_PASSWORD="your-password"
streamlit run app.py --server.address 0.0.0.0 --server.port 8501
```

### Docker / App Runner
```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY app.py .
EXPOSE 8501
CMD ["streamlit", "run", "app.py", "--server.port=8501", "--server.address=0.0.0.0"]
```

Pass environment variables at runtime:
```bash
docker run -p 8501:8501 \
  -e BEDROCK_AGENT_ID="your-agent-id" \
  -e APP_PASSWORD="your-password" \
  -e AWS_ACCESS_KEY_ID="..." \
  -e AWS_SECRET_ACCESS_KEY="..." \
  your-image
```

## Security Notes

- **APP_PASSWORD** provides basic protection for demos/labs
- For production, use proper authentication (Cognito, SSO)
- Use IAM roles instead of access keys when possible
- Never commit credentials to version control
