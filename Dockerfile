#1 Base Image
FROM python:3.12.1

#2 Set Working Directory
WORKDIR /app

#3 Copy dependency file first (for caching). If later we change our code and not requirements then docker won't redownload everything.
COPY requirements.txt .

#4 Install dependencies for C++ adn Python 
RUN pip install torch==2.4.0+cpu \ 
    --index-url https://download.pytorch.org/whl/cpu
RUN apt-get update && apt-get install -y build-essential \
    && pip install --no-cache-dir --default-timeout=1000 --retries=10 -r requirements.txt \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

#5 Copy app files. This is what actually moves your project code inside the container.
COPY . .

#6 Expose Streamlit port. Tells Docker that your app listens on port 8501 (Streamlit’s default).
EXPOSE 8501
EXPOSE 8000

#7 Run Streamlit. Launches your Streamlit app at port 8501, accessible from any network interface (0.0.0.0).
CMD ["streamlit", "run", "app.py", "--server.port=8501", "--server.address=0.0.0.0"]