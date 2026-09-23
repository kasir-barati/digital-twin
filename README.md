# How to Deploy

The architecture at a glance:

```text
User Browser
    ↓ HTTPS
CloudFront (CDN)
    ↓
S3 Static Website (Frontend)
    ↓ HTTPS API Calls
API Gateway
    ↓
Lambda Function (Backend)
    ↓
    ├── OpenAI API (for responses)
    └── S3 Memory Bucket (for persistence)
```

Key components are:

1. **CloudFront**: Global CDN, provides HTTPS, caches static content
2. **S3 Frontend Bucket**: Hosts static Next.js files
3. **API Gateway**: Manages API routes, handles CORS
4. **Lambda**: Runs your Python backend serverlessly
5. **S3 Memory Bucket**: Stores conversation history as JSON files

How to Minimize Costs

1. **Use CloudFront caching** - reduces requests to origin
2. **Set appropriate Lambda timeout** - don't set unnecessarily high
3. **Monitor with CloudWatch** - set up billing alerts
4. **Clean old S3 files** - delete old conversation logs periodically
5. **Use AWS Free option For CloudFront**

## 1. In AWS Console, search for **IAM**

1. Click **User groups** → **Create group**
2. Group name: `TwinAccess`
3. Attach the following policies - IMPORTANT see the last one added in to avoid permission issues later!
   - `AWSLambda_FullAccess` - For Lambda operations
   - `AmazonS3FullAccess` - For S3 bucket operations
   - `AmazonAPIGatewayAdministrator` - For API Gateway
   - `CloudFrontFullAccess` - For CloudFront distribution
   - `IAMFullAccess` - To view roles
   - `AmazonDynamoDBFullAccess_v2` - Needed on Day 4
4. Click **Create group**

## 2: Add User to Group

1. In IAM, click **Users** → Select `aiengineer` (from Week 1)
2. Click **Add to groups**
3. Select `TwinAccess`
4. Click **Add to groups**

## 3: Sign In as IAM User

1. Sign out from root account
2. Sign in as `aiengineer` with your IAM credentials

## 4: Build the Lambda Package

Make sure Docker Desktop is running, then:

```bash
cd backend
uv run deploy.py
```

This creates `lambda-deployment.zip` containing your Lambda function and all dependencies.

## 5: Create Lambda Function

### Create a new execution role in root account

1. Go to IAM → Roles → Create role.
2. Under **Trusted entity type**, choose **AWS service**, then **Lambda** as the **use case**. The console generates the trust policy with `lambda.amazonaws.com` and `sts:AssumeRole` for you.
3. On the permissions step, search for and attach `AWSLambdaBasicExecutionRole`. This is an existing AWS managed policy, so there's nothing to create.
4. Click **Add permissions** → **Attach policies**
5. Search and select: `AmazonS3FullAccess`
6. Click **Attach policies**
7. Name the role, e.g. `digital-twin-role`, and create it.

### Create Lambda Function itself

1. In AWS Console, search for **Lambda**
2. Click **Create function**
3. Choose **Author from scratch**
4. Configuration:
   - Function name: `twin-api`
   - Runtime: **Python 3.12**
   - Architecture: **x86_64**
5. Click **Create function**

### 6: Upload Your Code

1. In the Lambda function page, under **Code source**
2. Click **Upload from** → **.zip file**
3. Click **Upload** and select your `backend/lambda-deployment.zip`
4. Click **Save**

## 7: Configure Handler

1. In **Runtime settings**, click **Edit**
2. Change Handler to: `lambda_handler.handler`
3. Click **Save**

## 8: Configure Environment Variables

1. Click **Configuration** tab → **Environment variables**
2. Click **Edit** → **Add environment variable**
3. Add these variables:
   - `OPENAI_API_KEY` = your_openai_api_key
   - `CORS_ORIGINS` = `*` (we'll restrict this later)
   - `USE_S3` = `true`
   - `S3_BUCKET` = `twin-memory` (we'll create this next)
4. Click **Save**

## 9: Increase Timeout

1. In **Configuration** → **General configuration**
2. Click **Edit**
3. Set Timeout to **30 seconds**
4. Click **Save**

## 10: Test the Lambda Function

1. Click **Test** tab
2. Create new test event:
   - Event name: `HealthCheck`
   - Event template: **API Gateway AWS Proxy** (scroll down to find it)
   - Modify the Event JSON to:
   ```json
   {
     "version": "2.0",
     "routeKey": "GET /health",
     "rawPath": "/health",
     "headers": {
       "accept": "application/json",
       "content-type": "application/json",
       "user-agent": "test-invoke"
     },
     "requestContext": {
       "http": {
         "method": "GET",
         "path": "/health",
         "protocol": "HTTP/1.1",
         "sourceIp": "127.0.0.1",
         "userAgent": "test-invoke"
       },
       "routeKey": "GET /health",
       "stage": "$default"
     },
     "isBase64Encoded": false
   }
   ```
3. Click **Save** → **Test**
4. You should see a successful response with a body containing `{"status": "healthy", "use_s3": true}`

**Note**: The `sourceIp` and `userAgent` fields in `requestContext.http` are required by Mangum to properly handle the request.

## 11: Create S3 Buckets

1. In AWS Console, search for **S3**
2. Click **Create bucket**
3. Configuration:
   - Bucket name: `twin-memory-kasir-barati` (must be globally unique)
   - Region: Same as your Lambda (e.g., us-east-1)
   - Leave all other settings as default
4. Click **Create bucket**
5. Copy the exact bucket name

## 12: Update Lambda Environment

1. Go back to Lambda → **Configuration** → **Environment variables**
2. Update `S3_BUCKET` with your actual bucket name
3. Click **Save**

## 13: Create Frontend Bucket

1. Back in S3, click **Create bucket**
2. Configuration:
   - Bucket name: `twin-frontend-kasir-barati`
   - Region: Same as Lambda
   - **Uncheck** "Block all public access"
   - Check the acknowledgment box
3. Click **Create bucket**

## 14: Enable Static Website Hosting

1. Click on your frontend bucket
2. Go to **Properties** tab
3. Scroll to **Static website hosting** → **Edit**
4. Enable static website hosting:
   - Hosting type: **Host a static website**
   - Index document: `index.html`
   - Error document: `404.html`
5. Click **Save changes**
6. Note the **Bucket website endpoint** URL

## 15: Configure Bucket Policy

1. Go to **Permissions** tab
2. Under **Bucket policy**, click **Edit**
3. Add this policy (replace `YOUR-BUCKET-NAME`):

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "PublicReadGetObject",
         "Effect": "Allow",
         "Principal": "*",
         "Action": "s3:GetObject",
         "Resource": "arn:aws:s3:::YOUR-BUCKET-NAME/*"
       }
     ]
   }
   ```

4. Click **Save changes**

## 16: Set Up API Gateway

### Step 1: Create HTTP API with Integration

1. In AWS Console, search for **API Gateway**
2. Click **Create API**
3. Choose **HTTP API** → **Build**
4. **Step 1 - Create and configure integrations:**
   - Click **Add integration**
   - Integration type: **Lambda**
   - Lambda function: Select `twin-api` from the dropdown
   - API name: `twin-api-gateway`
   - Click **Next**

### Step 2: Configure Routes

1. **Step 2 - Configure routes:**
2. You'll see a default route already created. Click **Add route** to add more:

   **Existing route (update it):**

   - Method: `ANY`
   - Resource path: `/{proxy+}`
   - Integration target: `twin-api` (should already be selected)

   **Add these additional routes (click Add route for each):**

   Route 1:

   - Method: `GET`
   - Resource path: `/`
   - Integration target: `twin-api`

   Route 2:

   - Method: `GET`
   - Resource path: `/health`
   - Integration target: `twin-api`

   Route 3:

   - Method: `POST`
   - Resource path: `/chat`
   - Integration target: `twin-api`

   Route 4 (for CORS):

   - Method: `OPTIONS`
   - Resource path: `/{proxy+}`
   - Integration target: `twin-api`

3. Click **Next**

### Step 3: Configure Stages

1. **Step 3 - Configure stages:**
   - Stage name: `$default` (leave as is)
   - Auto-deploy: Leave enabled
2. Click **Next**

### Step 4: Review and Create

1. **Step 4 - Review and create:**
   - Review your configuration
   - You should see your Lambda integration and all routes listed
2. Click **Create**

### Step 5: Configure CORS

After creation, configure CORS:

1. In your newly created API, go to **CORS** in the left menu
2. Click **Configure**
3. Settings:
   - Access-Control-Allow-Origin: Type `*` and **click Add** (important: you must click Add!)
   - Access-Control-Allow-Headers: Type `*` and **click Add** (don't just type - click Add!)
   - Access-Control-Allow-Methods: Type `*` and **click Add** (or add `GET, POST, OPTIONS` individually)
   - Access-Control-Max-Age: `300`
4. Click **Save**

**Important**:

- For each field with multiple values (Origin, Headers, Methods), you must type the value and then click the **Add** button. The value won't be saved if you just type it without clicking Add!
- You do not need to "Deploy" your API after configuring CORS since it is an HTTP API and they are auto deployed.

### Step 6: Test Your API

1. Go to **API details** (or **Stages** → **$default**)
2. Copy your **Invoke URL** (looks like: `https://abc123xyz.execute-api.us-east-1.amazonaws.com`)
3. Test with a browser by visiting: https://YOUR-API-ID.execute-api.us-east-1.amazonaws.com/health

You should see: `{"status": "healthy", "use_s3": true}`

**Note**: If you get a "Missing Authentication Token" error, make sure you're using the exact path `/health` and not just the base URL.

## 17: Deploy Frontend

1. We have `NEXT_PUBLIC_API_URL` which dictates the API URL. Create `frontend/.env.local` with `NEXT_PUBLIC_API_URL=https://asd123.execute-api.eu-central-1.amazonaws.com` Or leave it blank and use the default local URL.
2. Build static export:
   ```bash
   cd frontend
   npm run build
   ```
3. Upload to S3:

   ```bash
   cd frontend
   aws s3 sync out/ s3://twin-frontend-kasir-barati/ --delete
   ```

   Just make sure you have executed `aws configure` with your AWS credentials first.

   The `--delete` flag ensures that old files are removed from S3 if they're no longer in your build.

4. Go to your S3 bucket → **Properties** → **Static website hosting**
5. Click the **Bucket website endpoint** URL
6. Your twin should load! But CORS might block API calls...

## 18: Set Up CloudFront

### Step 1: Get Your S3 Website Endpoint

First, you need your S3 static website URL (not the bucket name):

1. Go to S3 → Your frontend bucket
2. Click **Properties** tab
3. Scroll to **Static website hosting**
4. Copy the **Bucket website endpoint** (looks like: `http://twin-frontend-xxx.s3-website-us-east-1.amazonaws.com`)
5. Save this URL - you'll need it for CloudFront

### Step 2: Create CloudFront Distribution

1. In AWS Console, search for **CloudFront**
2. Click **Create distribution**
3. You will be prompted to 'Choose a plan'. Scroll to the bottom and choose **Pay as you go**.

   IMPORTANT: DO NOT choose the 'free' plan. You won't be able to delete the distribution created until you cancel the subscription and wait for the end of billing cycle. It's a trap!!

4. **Step 1 - Origin:**
   - Distribution name: `twin-distribution`
   - Click **Next**
5. **Step 2 - Add origin:**
   - Choose origin: Select **Other** (not Amazon S3!)
   - Origin domain name: Paste your S3 website endpoint WITHOUT the http://
     - Example: `twin-frontend-xxx.s3-website-us-east-1.amazonaws.com`
   - **Origin protocol policy**: Select **HTTP only** (CRITICAL - not HTTPS!)
     - This is because S3 static website hosting doesn't support HTTPS
     - If you select HTTPS, you'll get 504 Gateway Timeout errors
   - Origin name: `s3-static-website` (or leave auto-generated)
   - Leave other settings as default
   - Click **Add origin**
6. **Step 3 - Default cache behavior:**
   - Path pattern: Leave as `Default (*)`
   - Origin and origin groups: Select your origin
   - Viewer protocol policy: **Redirect HTTP to HTTPS**
   - Allowed HTTP methods: **GET, HEAD**
   - Cache policy: **CachingOptimized**
   - Click **Next**
7. **Step 4 - Web Application Firewall (WAF):**
   - Select **Do not enable security protections** (saves $14/month)
   - Click **Next**
8. **Step 5 - Settings:**
   - Price class: **Use only North America and Europe** (to save costs)
   - Default root object: `index.html`
   - Click **Next**
9. **Review** and click **Create distribution**

## 19: Wait for Deployment

CloudFront takes 5-15 minutes to deploy globally. Status will change from "Deploying" to "Enabled".

## 20: Update CORS Settings

While waiting for CloudFront to deploy, update your Lambda to accept requests from CloudFront:

1. Go to Lambda → **Configuration** → **Environment variables**
2. Find your CloudFront distribution domain:
   - Go to CloudFront → Your distribution
   - Copy the **Distribution domain name** (like `d1234abcd.cloudfront.net`)
3. Edit the `CORS_ORIGINS` environment variable:
   - Current value: `*`
   - New value: `https://YOUR-CLOUDFRONT-DOMAIN.cloudfront.net`
   - It matches the CloudFront URL, it includes `https://` at the start, and there's **no** `/` at the end, and it looks just like the example
   - Example: `https://d1234abcd.cloudfront.net`
4. Click **Save**

## 21: Invalidate CloudFront Cache

1. In CloudFront, select your distribution
2. Go to **Invalidations** tab
3. Click **Create invalidation**
4. Add path: `/*`
5. Click **Create invalidation**

---

## Cleanup

- Empty the AWS S3 buckets, then delete them.
- Delete the Lambda function.
- Disable the CloudFront distribution and then cancel the free flat-rate pricing plan, and now you should be able to delete it. Of course you will have to wait after disabling the CloudFront distribution before you can cancel the subscription plan and delete it.

---

## Bedrock

1. You need to change the `backend/server.py` file to switch to Bedrock instead of OpenAI.
2. You need to give the execution role you have for your Lambda function to have access to Bedrock.
   - The way we do this without any API key is because we are already inside the AWS ecosystem.
3. You can see you called Amazon's Bedrock in the CloudWatch logs.

---

## Terraform

Create `LambdaExecutionRoleProvisioner` and assign it to the user who will be running the terraform:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LambdaRoleLifecycle",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy"
      ],
      "Resource": "arn:aws:iam::637423441352:role/*-lambda-role"
    },
    {
      "Sid": "LambdaRolePassToLambdaOnly",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::637423441352:role/*-lambda-role",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "lambda.amazonaws.com"
        }
      }
    },
    {
      "Sid": "LambdaRoleAttachKnownPoliciesOnly",
      "Effect": "Allow",
      "Action": ["iam:AttachRolePolicy", "iam:DetachRolePolicy"],
      "Resource": "arn:aws:iam::637423441352:role/*-lambda-role",
      "Condition": {
        "ArnEquals": {
          "iam:PolicyARN": [
            "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
            "arn:aws:iam::aws:policy/AmazonBedrockFullAccess",
            "arn:aws:iam::aws:policy/AmazonS3FullAccess"
          ]
        }
      }
    }
  ]
}
```

Create `AIEngineerUserManagement` amd assign it to the user too:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageOwnUserTagsAndCredentials",
      "Effect": "Allow",
      "Action": [
        "iam:TagUser",
        "iam:ListUserTags",
        "iam:UntagUser",
        "iam:ListMFADevices",
        "iam:ListSigningCertificates",
        "iam:GetLoginProfile"
      ],
      "Resource": "arn:aws:iam::637423441352:user/aiengineer"
    }
  ]
}
```

And `AIEngineerAccessKeySelfService` with:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageOwnAccessKeys",
      "Effect": "Allow",
      "Action": [
        "iam:CreateAccessKey",
        "iam:UpdateAccessKey",
        "iam:DeleteAccessKey",
        "iam:ListAccessKeys",
        "iam:GetAccessKeyLastUsed"
      ],
      "Resource": "arn:aws:iam::637423441352:user/aiengineer"
    }
  ]
}
```

On top of that I had granted the user these permissions:

- `AmazonBedrockFullAccess`.
- `AmazonAPIGatewayAdministrator`.
- `CloudFrontFullAccess`.
- `AmazonS3FullAccess`.
- `AmazonEC2ContainerRegistryFullAccess`.
- `AWSAppRunnerFullAccess`.
- `AWSLambda_FullAccess`.
- `CloudWatchFullAccess`.
- `CloudWatchFullAccessV2`.
- `CloudWatchLogsFullAccess`.
- `IAMUserChangePassword`.

`AmazonBedrockFullAccess` and `AmazonS3FullAccess` are both AWS managed "FullAccess" policies — much broader than a Lambda function typically needs. They must be limited to what Lambda function needs.

Potential improvements:

1. Store Terraform state file in a AWS S3.
2. `aws_iam_role_policy_attachment.lambda_s3` uses `AmazonS3FullAccess` (access to every bucket in the account) and `lambda_bedrock` similarly uses `AmazonBedrockFullAccess`. Both are broader than the Lambda needs — it only touches `aws_s3_bucket.memory` and one Bedrock model (`var.bedrock_model_id`).
3. CloudFront → S3 origin uses `origin_protocol_policy = "http-only"`, so traffic between CloudFront and the S3 website endpoint is unencrypted. Also related: the frontend bucket is fully public (`block_public_*` all false) rather than using Origin Access Control.

### Terraform State in AWS S3

For this we have the `terraform-bootstrap` directory, which provisions everything that must exist *before* GitHub Actions can run Terraform at all: the S3 state bucket, the GitHub OIDC provider, and the IAM role GitHub Actions assumes. This is a chicken-and-egg problem — CI can't create the resources it needs to run — so this directory is applied only by a human, locally, never by CI. See `terraform-bootstrap/README.md` for details.

First go to your AWS Console and create an access key for the IAM user you have access to, and it must be allowed to create AWS S3 bucket. E.g. here I have already an IAM user with necessary permissions to create such resource. In fact I am using the same IAM user which terraform will use to provision the digital twin.

```bash
aws configure --profile twin-dev
cd terraform-bootstrap
terraform init
terraform apply
```
