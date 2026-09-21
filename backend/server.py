import json
import os
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import TypedDict

import boto3
from botocore.exceptions import ClientError
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# Load environment variables
load_dotenv(override=True)

app = FastAPI()

# Configure CORS
origins = os.getenv("CORS_ORIGINS", "http://localhost:3000").split(",")
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


class ChatMessage(TypedDict):
    role: str
    content: str


# Initialize Bedrock client - see Q42 on https://edwarddonner.com/faq if the Region gives you problems
bedrock_client = boto3.client(
    service_name="bedrock-runtime",
    region_name=os.getenv("DEFAULT_AWS_REGION", "us-east-1"),
)

# Bedrock model selection - see Q42 on https://edwarddonner.com/faq for more
BEDROCK_MODEL_ID = os.getenv("BEDROCK_MODEL_ID", "global.amazon.nova-2-micro-v1:0")

# Memory storage configuration
USE_S3 = os.getenv("USE_S3", "false").lower() == "true"
S3_BUCKET = os.getenv("S3_BUCKET", "")
MEMORY_DIR = Path("../memory")

if USE_S3:
    s3_client = boto3.client("s3")
else:
    MEMORY_DIR.mkdir(exist_ok=True)


# Load personality details
def load_personality():
    with open("system-prompt.txt", "r", encoding="utf-8") as f:
        raw_data = f.read().strip()
        return raw_data.replace(
            "{{today}}", datetime.now(UTC).strftime("%Y-%m-%d %H:%M:%S")
        )


PERSONALITY = load_personality()


def call_bedrock(conversation: list[ChatMessage], user_message: str) -> str:
    """Call AWS Bedrock with conversation history"""
    messages = [
        {"role": msg["role"], "content": [{"text": msg["content"]}]}
        for msg in conversation
    ]
    messages.append({"role": "user", "content": [{"text": user_message}]})

    try:
        response = bedrock_client.converse(
            modelId=BEDROCK_MODEL_ID,
            messages=messages,
            system=[{"text": PERSONALITY}],
            inferenceConfig={"maxTokens": 2000, "temperature": 0.7, "topP": 0.9},
        )
        return response["output"]["message"]["content"][0]["text"]
    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        if error_code == "ValidationException":
            raise HTTPException(
                status_code=400, detail="Invalid message format for Bedrock"
            ) from e
        elif error_code == "AccessDeniedException":
            raise HTTPException(
                status_code=403, detail="Access denied to Bedrock model"
            ) from e
        raise HTTPException(status_code=500, detail=f"Bedrock error: {e}") from e


def load_conversation(session_id: str) -> list[ChatMessage]:
    """Load conversation history from storage"""
    if USE_S3:
        try:
            response = s3_client.get_object(Bucket=S3_BUCKET, Key=f"{session_id}.json")
            return json.loads(response["Body"].read().decode("utf-8"))
        except ClientError as e:
            if e.response["Error"]["Code"] == "NoSuchKey":
                return []
            raise

    file_path = MEMORY_DIR / f"{session_id}.json"
    if file_path.exists():
        with open(file_path, "r", encoding="utf-8") as f:
            return json.load(f)
    return []


def save_conversation(session_id: str, messages: list[ChatMessage]):
    """Save conversation history to storage"""
    if USE_S3:
        s3_client.put_object(
            Bucket=S3_BUCKET,
            Key=f"{session_id}.json",
            Body=json.dumps(messages, indent=2, ensure_ascii=False),
            ContentType="application/json",
        )
        return

    file_path = MEMORY_DIR / f"{session_id}.json"
    with open(file_path, "w", encoding="utf-8") as f:
        json.dump(messages, f, indent=2, ensure_ascii=False)


# Request/Response models
class ChatRequest(BaseModel):
    message: str
    session_id: str | None = None


class ChatResponse(BaseModel):
    response: str
    session_id: str


@app.get("/")
async def root():
    return {
        "message": "AI Digital Twin API with Memory (Powered by AWS Bedrock)",
        "storage": "S3" if USE_S3 else "local",
        "ai_model": BEDROCK_MODEL_ID,
    }


@app.get("/health")
async def health_check():
    return {"status": "healthy", "use_s3": USE_S3, "bedrock_model": BEDROCK_MODEL_ID}


@app.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest):
    try:
        # Generate session ID if not provided
        session_id = request.session_id or str(uuid.uuid4())

        # Load conversation history
        conversation = load_conversation(session_id)

        # Call Bedrock for response
        assistant_response = call_bedrock(conversation, request.message)

        # Update conversation history
        conversation.append({"role": "user", "content": request.message})
        conversation.append({"role": "assistant", "content": assistant_response})

        # Save updated conversation
        save_conversation(session_id, conversation)

        return ChatResponse(response=assistant_response, session_id=session_id)

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e)) from e


@app.get("/sessions")
async def list_sessions():
    """List all conversation sessions"""
    sessions = []

    if USE_S3:
        response = s3_client.list_objects_v2(Bucket=S3_BUCKET)
        for obj in response.get("Contents", []):
            session_id = Path(obj["Key"]).stem
            conversation = load_conversation(session_id)
            sessions.append(
                {
                    "session_id": session_id,
                    "message_count": len(conversation),
                    "last_message": conversation[-1]["content"]
                    if conversation
                    else None,
                }
            )
        return {"sessions": sessions}

    for file_path in MEMORY_DIR.glob("*.json"):
        session_id = file_path.stem
        with open(file_path, "r", encoding="utf-8") as f:
            conversation = json.load(f)
            sessions.append(
                {
                    "session_id": session_id,
                    "message_count": len(conversation),
                    "last_message": conversation[-1]["content"]
                    if conversation
                    else None,
                }
            )
    return {"sessions": sessions}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
