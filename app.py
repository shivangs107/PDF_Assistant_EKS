import streamlit as st
from BackendLogic import PDFChatAssistant #Backend logic

st.set_page_config(page_title="PDF Chat Assistant", page_icon="📘", layout="wide")

# --- Header ---
st.title("📘 Chat with your PDF")
st.caption("Upload a PDF and ask anything from it")

# --- Upload Section ---
uploaded_file = st.file_uploader("Upload your PDF", type=["pdf"])
if uploaded_file:
    #Only process once per file
    if "assistant" not in st.session_state or st.session_state.pdf_name != uploaded_file.name:
        with st.spinner("Processing PDF..."):
            st.session_state.assistant = PDFChatAssistant(uploaded_file)
            st.session_state.pdf_name = uploaded_file.name
        st.success("PDF processed successfully! You can start chatting below 👇")
    else:
        st.info(f"Using cached PDF: {st.session_state.pdf_name}")
    assistant = st.session_state.assistant

    # --- Chat Interface ---
    if "messages" not in st.session_state:
        st.session_state.messages = []

    # Display previous messages
    for msg in st.session_state.messages:
        with st.chat_message(msg["role"]):
            st.markdown(msg["content"])

    # User input
    if prompt := st.chat_input("Ask a question about your PDF"):
        # Display user message
        st.chat_message("user").markdown(prompt)
        st.session_state.messages.append({"role": "user", "content": prompt})

        # Get model response
        with st.chat_message("assistant"):
            placeholder = st.empty()
            try:
                with st.spinner("Thinking..."):
                    answer = assistant.query(prompt)
            except Exception as e:
                answer = f"⚠️ Error while generating response: {e}"
            placeholder.markdown(answer)
        st.session_state.messages.append({"role": "assistant", "content": answer})