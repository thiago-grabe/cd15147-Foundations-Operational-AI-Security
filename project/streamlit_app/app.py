import streamlit as st
import boto3
import uuid
import os
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

st.set_page_config(page_title="Northstar Assist", page_icon="⭐")

# =============================================================================
# Configuration from environment variables (loaded from .env)
# =============================================================================
AGENT_ID = os.environ.get("BEDROCK_AGENT_ID", "your-agent-id")
AGENT_ALIAS_ID = os.environ.get("BEDROCK_AGENT_ALIAS_ID", "TSTALIASID")
REGION = os.environ.get("AWS_REGION", "us-east-1")
APP_PASSWORD = os.environ.get("APP_PASSWORD", "")  # Empty = no auth required

# =============================================================================
# Authentication
# =============================================================================
def check_password():
    """Simple password authentication. Returns True if authenticated."""
    # If no password is set, skip authentication
    if not APP_PASSWORD:
        return True

    if "authenticated" not in st.session_state:
        st.session_state.authenticated = False

    if st.session_state.authenticated:
        return True

    # Show login form
    st.title("🔐 Login Required")
    password = st.text_input("Password", type="password")

    if st.button("Login"):
        if password == APP_PASSWORD:
            st.session_state.authenticated = True
            st.rerun()
        else:
            st.error("Incorrect password")

    return False

# Check authentication before showing the app
if not check_password():
    st.stop()

# =============================================================================
# Main App (only runs if authenticated)
# =============================================================================
st.title("Northstar Assist")
st.write("""
Welcome to Northstar Assist! This system is designed for Northstar employees
to ask questions about our company's strategy, policies, procedures, and
internal documentation. Simply type your question below and get instant answers powered by AI.
""")

# Clear chat button
col1, col2 = st.columns([6, 1])
with col2:
    if st.button("Clear"):
        st.session_state.messages = []
        st.session_state.session_id = str(uuid.uuid4())
        st.rerun()

# Initialize Bedrock client
@st.cache_resource
def get_bedrock_client():
    return boto3.client("bedrock-agent-runtime", region_name=REGION)

client = get_bedrock_client()

# Session state
if "session_id" not in st.session_state:
    st.session_state.session_id = str(uuid.uuid4())
if "messages" not in st.session_state:
    st.session_state.messages = []

# Display chat history
for msg in st.session_state.messages:
    with st.chat_message(msg["role"]):
        st.markdown(msg["content"])

# Chat input
if prompt := st.chat_input("Ask a question about Northstar..."):
    # Add user message
    st.session_state.messages.append({"role": "user", "content": prompt})
    with st.chat_message("user"):
        st.markdown(prompt)

    # Call Bedrock Agent
    with st.chat_message("assistant"):
        with st.spinner("Thinking..."):
            try:
                response = client.invoke_agent(
                    agentId=AGENT_ID,
                    agentAliasId=AGENT_ALIAS_ID,
                    sessionId=st.session_state.session_id,
                    inputText=prompt
                )

                # Parse streaming response
                answer = ""
                for event in response["completion"]:
                    if "chunk" in event:
                        answer += event["chunk"]["bytes"].decode()

                st.markdown(answer)
                st.session_state.messages.append({"role": "assistant", "content": answer})

            except Exception as e:
                error_msg = f"Error: {str(e)}"
                st.error(error_msg)
                st.session_state.messages.append({"role": "assistant", "content": error_msg})

# Logout button (only if password auth is enabled)
if APP_PASSWORD:
    if st.button("Logout"):
        st.session_state.authenticated = False
        st.rerun()
