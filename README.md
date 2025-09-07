AWS End-to-End CI/CD for a Containerized Python App

Hi, I’m Jha’Mel. This repo demonstrates an end-to-end CI/CD pipeline on AWS for a small Flask app running in Docker.

A push to this GitHub repo triggers AWS CodePipeline, which uses CodeBuild to build and push a Docker image to Docker Hub, then uses CodeDeploy to deploy the latest image on an EC2 instance.

🚀 What This Project Shows

Practical CI/CD on AWS: CodePipeline → CodeBuild → CodeDeploy

Dockerized Python app with health endpoint

Secrets pulled from SSM Parameter Store in the build stage

Safe, simple lifecycle scripts to stop/remove the old container and run the new one

🔄 How It Works

Source (GitHub)
Commit to this repository triggers CodePipeline.

Build (CodeBuild)

Starts Docker-in-Docker

Logs into Docker Hub with creds from Parameter Store

Builds and pushes jhamelthorne/myapp:latest

Deploy (CodeDeploy on EC2)

ApplicationStop → scripts/stop_container.sh

AfterInstall → scripts/start_container.sh

Run (EC2)

Container listens on port 5000

Endpoints: / and /health

📂 Repository Structure
.
├─ appspec.yml               # CodeDeploy hooks → start/stop container
├─ buildspec.yml             # CodeBuild → build & push Docker image
├─ scripts/
│  ├─ start_container.sh     # pull & run latest image
│  └─ stop_container.sh      # stop/remove existing container
└─ simple-python-app/
   ├─ app.py                 # Flask app (/, /health)
   ├─ requirements.txt       # flask
   └─ Dockerfile             # EXPOSE 5000; CMD ["python","app.py"]

🗂 Key Files
appspec.yml (CodeDeploy)
version: 0.0
os: linux
hooks:
  ApplicationStop:
    - location: scripts/stop_container.sh
      timeout: 300
      runas: root
  AfterInstall:
    - location: scripts/start_container.sh
      timeout: 300
      runas: root

buildspec.yml (CodeBuild – excerpt)
version: 0.2
env:
  parameter-store:
    DOCKER_REGISTRY_USERNAME: /myapp/docker-credentials/username
    DOCKER_REGISTRY_PASSWORD: /myapp/docker-credentials/password
    DOCKER_REGISTRY_URL: /myapp/docker-registry/url

phases:
  install:
    runtime-versions:
      python: 3.11
    commands:
      - nohup /usr/local/bin/dockerd \
        --host=unix:///var/run/docker.sock \
        --host=tcp://127.0.0.1:2376 \
        --storage-driver=overlay2 &
      - timeout 15 sh -c "until docker info; do echo .; sleep 1; done"
  pre_build:
    commands:
      - echo $DOCKER_REGISTRY_PASSWORD | docker login -u $DOCKER_REGISTRY_USERNAME --password-stdin
      - pip install -r simple-python-app/requirements.txt
  build:
    commands:
      - cd simple-python-app
      - docker build -t jhamelthorne/myapp:latest .
      - docker push jhamelthorne/myapp:latest

Lifecycle Scripts

scripts/stop_container.sh

#!/usr/bin/env bash
set -e

NAME="simple-python-app"
docker rm -f "$NAME" >/dev/null 2>&1 || true
echo "[stop] Ensured $NAME is not running."


scripts/start_container.sh

#!/usr/bin/env bash
set -e

IMAGE="jhamelthorne/myapp:latest"
NAME="simple-python-app"
PORT="5000"   # matches app.py and Dockerfile

echo "[start] Pulling latest image: $IMAGE"
docker pull "$IMAGE"

echo "[start] Starting container $NAME on :$PORT"
docker run -d --name "$NAME" --restart=always -p ${PORT}:5000 "$IMAGE"

# Lightweight, non-fatal sanity check
sleep 2
if curl -fsS "http://localhost:${PORT}/health" >/dev/null; then
  echo "[start] Health OK."
else
  echo "[start] App starting; health endpoint not ready yet."
fi

Application (Flask)

app.py

from flask import Flask
app = Flask(__name__)

@app.route('/')
def hello():
    return '<h1>Hello, World! Your CI/CD Pipeline is working!</h1>'

@app.route('/health')
def health():
    return {'status': 'healthy', 'message': 'Application is running successfully'}

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)


Dockerfile

FROM python:3.8
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
EXPOSE 5000
CMD ["python", "app.py"]

⚙️ One-Time Setup

EC2:

Amazon Linux 2, Docker installed, CodeDeploy agent installed

Security group allows inbound 5000 (or route via ALB)

IAM:

CodeBuild role: ssm:GetParameters, CloudWatch Logs

CodeDeploy service role: standard deploy permissions

EC2 instance profile: S3 read for CodeDeploy bundle

Parameter Store:

/myapp/docker-credentials/username

/myapp/docker-credentials/password

/myapp/docker-registry/url

🏃 Run Locally
cd simple-python-app
docker build -t myapp:local .
docker run -p 5000:5000 myapp:local


Test at:

http://localhost:5000

http://localhost:5000/health

🔧 Troubleshooting

Port/name in use: handled by stop_container.sh

Image push fails: check Docker Hub creds in Parameter Store

App unreachable: confirm EC2 SG allows 5000; check docker logs simple-python-app

Health flaky: run curl -v http://localhost:5000/health on EC2

📈 Next Steps (Future Enhancements)

Add a small pytest to test /health in CodeBuild

Use python:3.11-slim as base image for security/performance

Push to ECR and deploy with ECS Fargate

Send logs to CloudWatch Logs and add alarms
