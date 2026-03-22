# 📘 PDF_Assistant_EKS

A scalable PDF Question-Answering system deployed on AWS EKS using Terraform, with full observability using Prometheus and Grafana.

## 🚀 Features

- 📄 Upload PDF and ask questions
- 🧠 Semantic search using embeddings (FAISS + Sentence Transformers)
- 🤖 AI-powered responses (OpenAI)
- 📊 Metrics exposed via Prometheus
- 📈 Monitoring dashboard with Grafana
- ☁️ Fully deployed on AWS EKS using Terraform
- ⚙️ Clean 2-stage Terraform architecture (Infra + K8s)

## 🏗️ Architecture

User → Streamlit App → Backend Logic  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;↓ 
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Prometheus Metrics (/metrics)  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;↓ 
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Prometheus (EKS)  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;↓ 
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Grafana Dashboard  

## 📁 Project Structure

├── terraform/  
│ ├── eks/ # EKS infrastructure (Stage 1)  
│ └── k8s/ # Kubernetes resources (Stage 2)  
├── app.py # Streamlit UI  
├── BackendLogic.py # Core PDF + AI logic  
├── Dockerfile # Container image  
├── requirements.txt  
├── .env

## ⚙️ Tech Stack

- **Frontend:** Streamlit
- **Backend:** Python
- **Vector Search:** FAISS
- **Embeddings:** Sentence Transformers
- **LLM:** OpenAI API
- **Containerization:** Docker
- **Orchestration:** Kubernetes (EKS)
- **IaC:** Terraform
- **Monitoring:** Prometheus + Grafana

## ⚙️ Tech Stack

1. Upload PDF
2. Text is chunked and embedded
3. Stored in FAISS index
4. Query → semantic search → relevant chunks
5. OpenAI generates answer
6. Metrics exposed via /metrics

## 📊 Metrics Collected

- pdf_upload_total
- pdf_queries_total
- query_latency_seconds

## ☁️ Deployment Guide
**Prerequisites:**
1. Have an AWS account
   - Go to: https://aws.amazon.com/
   - Sign up and complete billing setup
   - Create IAM User:
     - Go to IAM → Users → Create User
     - Enable: Pragrammatic Access
     - Attach policies: AdministratorAccess (for learning phase)
   - Generate Access Keys:
     - Copy Access Key ID and Secret Access Key
2. Installed AWS CLI
   - https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
   - Verify: `aws --version`
   - Configure AWS locally:
     - In powershell/cmd: aws configure
     - Fill:
        - AWS Access Key ID
        - AWS Secret Access Key
        - Region: ap-south-1 (or any other but remember to put it same everywhere if you are a beginner otherwise its confusing)
        - Output format: json
    - Verify: `aws sts get-caller-identity`
3. Store OpenAI PI Key in AWS SSM
   - Create Parameter
     - Go to: AWS Console → System Manager → Parameter Store
     - Create (Remeber to keep it as it is or just remeber what you have put and replace it with the changes):
       - Name: OPENAI_API_KEY
       - Type: SecureString
       - Value: your-openeai-api-key
4. Install Terraform
   - Download: https://developer.hashicorp.com/terraform/downloads
   - Verify: `terraform -version`
5. Install Docker Desktop (if you want to save this image to your dockerhub or want to create a new image with changes)
   - Download: https://www.docker.com/products/docker-desktop/
   - Ensure Docker is running: `docker --version`
   - Create DockerHub Account: https://hub.docker.com/
   - Login locally: `docker login`
6. Install kubectl (Best option is to install chocolatey and install these via it. You can check it out through ChatGPT)
   - Install: https://kubernetes.io/docs/tasks/tools/
   - Verify: `kubectl version --client`
7. Insatll Helm
   - Install: https://helm.sh/docs/intro/install/
   - Verify: `helm version`
8. Install Git
   - Download: https://git-scm.com/downloads
   - Verify: `git --version`
9. Clone Repo (If its your first time using git then watch a video on how to properly link git with github)
   - `git clone <your-repo-url>`
   - `cd <repo-folder>`
10. Setup Environment Variables
    - Create .env file: OPENAI_API_KEY=your-openai-api-key
11. Build and push docker image (You can change name too if you want)
    - `docker build -t <your-dockerhub-username>/pdf-assistant-eks:latest .`
    - `docker push <your-dockerhub-username>/pdf-assistant-eks:latest`
12. Update Image in Terraform
    - In terraform/k8s/main.tf: image = "<your-dockerhub-username>/pdf-assistant-eks:latest"
   
**These are the steps I remeber and haven't hard coded on a new device so....ALL THE BEST LOL**  
**Before Going into the kubernetes deployment, kindly check your docker image too after building like this:**  
`docker run --env-file .env -p 8501:8501 -p 8000:8000 pdf-assistant-eks` (or the name you provided)  
Test: 
  - http://localhost:8501
  - http://localhost:8000/metrics  
If everything works then atleast you can run the program locally...

---

### 💎 Step 1 — Deploy EKS (Infra Layer) (10 min)
- `cd terraform/eks` (Naviaget to your directory)  
- `terraform init`  
- `terraform apply -auto-approve` (⚠️ This will create the EKS cluster and billing will start)

---

### 💎 Step 2 — Configure Kubernetes (For checking purpose, not a necessity)
- `aws eks update-kubeconfig --name pdf-assistant-cluster --region ap-south-1`  
- `kubectl get nodes`

---

### 💎 Step 3 — Deploy Application + Monitoring (2 min)
- `cd terraform/k8s`  
- `terraform init`  
- `terraform apply -auto-approve`
  🚀 This will start:
  - Streamlit UI  
  - Grafana dashboard  
  - Prometheus metrics    

### 💎 Step 4 — Getting App url and grafana link  
- Initially you will only get app_url link and grafana_url will show pending... as it takes time. After 1-2 min just do:
- `terraform refresh`

---

# 🔴 **If you get stuck somewhere just copy paste these commands and paste it on ChatGPT and it might help**
- `docker ps`
- `docker images`
- `kubectl get nodes`
- `kubectl get svc`
- `kubectl logs <get.pods_name>`

## 🌐 Access Application

After deployment: terraform output  
It will give two links and you just have to paste it on the browser.  
Although doing just terraform apply will also give the same but grafana takes a little time so it might pending..., hence the use of output after 1-2 mins.  

## 🔐 Grafana Login

**Username:** admin  
**Password:** type/paste this in powershell:  
`kubectl get secret monitoring-grafana -o jsonpath="{.data.admin-password}" | %{ [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_)) }`

## 📈 Monitoring Setup

- Prometheus auto-scrapes /metrics
- ServiceMonitor configured via Helm
- Grafana dashboards need manual creation

## 🧹 Destroy Infrastructure

⚠️ **Always destroy in order**
- `cd terraform/k8s`  
- `terraform destroy -auto-approve` → 1 min  
- `cd ../eks`  
- `terraform destroy -auto-approve` → 9 min  

## ⚠️ Common Issues

1. ❌ ServiceMonitor not working
   - Fixed by using Helm-based ServiceMonitor
   - Do Not use kubernetes_manifest
  
2. ❌ Grafana URL pending
   - Wait 2-3 minutes for LoadBalancer

3. ❌ App not opening
   - Ensure Streamlit runs on: streamlit run app.py --server.address 0.0.0.0 --server.port 8501
  
4. ❌ Terraform destroy fails
   - Always destroy k8s before eks
  
5. ❌ Terraform plan fails on k8s
   - If the error is: data.terraform_remote_state.eks.outputs is object with no attributes
   - It means: Our EKS Terraform state has No outputs defined.
   - It will start working once you do terraform apply on eks.
  
# 🔥 Key Learnings

- Terraform + EKS + Kubernetes in one step → unreliable
- Use 2-stage Terraform architecture
- Avoid time_sleep and heavy depends_on
- Handle CRDs via Helm (best practice)
- If you are going with minikube then don't use terraform as it is very confusing and terraform won't be even needed much.
- Always remember to not do hit and trial things while eks is running otherwise your aws bill will explode.

## 🚀 Future Improvements

- CI/CD pipeline (GitHub Actions)
- Auto Grafana Dashboards
- Persistent storage (S3/EFS)
- Multi-node scaling
- Authentication for app
