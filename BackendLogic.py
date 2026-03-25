#Libraries
import re
import fitz
from sentence_transformers import SentenceTransformer
import numpy as np
import time
import faiss
from sklearn.metrics.pairwise import cosine_similarity
import tempfile
from pathlib import Path
import streamlit as st
import os
from dotenv import load_dotenv
load_dotenv()
from openai import OpenAI
from prometheus_client import Counter, Histogram, start_http_server

try:
    start_http_server(8000)
    print("✅ Prometheus metrics server started on port 8000")
except Exception as e:
    print(f"⚠️ Metrics server error: {e}")

# Prometheus Metrics
PDF_UPLOAD_COUNTER = Counter("pdf_uploaded_total", "Total PDFs uploaded", ["status"])
QUERY_COUNTER = Counter("pdf_queries_total", "Total user queries", ["status"])
QUERY_LATENCY = Histogram("query_latency_seconds", "Time taken to answer queries", ["status"])

client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))

class PDFChatAssistant:
    def __init__(self, pdf_file):
        self.pdf_file = pdf_file
        
        #Track Upload
        PDF_UPLOAD_COUNTER.labels(status="success").inc()
        self.load_and_index_pdf()

    def load_and_index_pdf(self):
        # --- 1. Sentence-safe chunking ---
        def smart_chunk_text(text, chunk_size=120, overlap=40):
            #overlap: unused (sentence-level overlap is fixed to 2 sentence)
            separators = re.compile(r'(\n\n|\n|[.!?])')
            parts = separators.split(text)
            chunks = []
            current_chunk = ""
            last_checkpoint = ""

            def count_words(s):
                return len(s.split())
            
            for part in parts:
                current_chunk += part
                if re.match(separators, part):
                    last_checkpoint = current_chunk
                if count_words(current_chunk) >= chunk_size:
                    if last_checkpoint:
                        chunks.append(last_checkpoint.strip())
                        '''This is word based overlap
                        overlap_words = " ".join(last_checkpoint.split()[-overlap:])
                        current_chunk = overlap_words
                        '''
                        #Sentence Based Overlap
                        sentences = re.split(r'(?<=[.!?])\s+', last_checkpoint.strip())
                        overlap_sentences = sentences[-2:]
                        current_chunk = " ".join(overlap_sentences)                      
                        last_checkpoint = ""
                    else:
                        chunks.append(current_chunk.strip())
                        current_chunk = ""
            if current_chunk.strip():
                chunks.append(current_chunk.strip())
            return chunks
        
        # --- 2. Read and chunk the PDF ---
        pdf_bytes = self.pdf_file.getvalue() 
        self.pdf_path = tempfile.NamedTemporaryFile(delete=False, suffix=".pdf").name                     
        with open(self.pdf_path, "wb") as f:
            f.write(pdf_bytes)
        doc = fitz.open(self.pdf_path)     
        
        chunk_metadata = []
        for page_num in range(doc.page_count):
            page = doc.load_page(page_num)
            text = page.get_text("text")
            page_chunks = smart_chunk_text(text, chunk_size=120, overlap=40)
            for chunk in page_chunks:
                chunk_metadata.append({'text': chunk, 'page': page_num + 1})
        chunks = [c['text'] for c in chunk_metadata]
        st.write("Total chunks:", len(chunks))
        
        # --- 3. Embed chunks ---
        start = time.time()
        st.write("Embedding all chunks... ")
        model = SentenceTransformer('multi-qa-MiniLM-L6-cos-v1')
        
        def embed_chunks(chunks):
            progress_bar = st.progress(0)
            status_text = st.empty()
            embeddings = []

            total = len(chunks)
            for i, chunk in enumerate(chunks):
                emb = model.encode(chunk, normalize_embeddings=True)
                embeddings.append(emb)

                # update Streamlit progress bar
                progress_bar.progress((i + 1) / total)
                status_text.text(f"Embedding chunk {i + 1}/{total}")

            progress_bar.empty()
            status_text.empty()

            return np.array(embeddings).astype("float32")

        embeddings = embed_chunks(chunks)
        end = time.time()
        st.write(f"✅ Embedding completed in {end - start:.2f} seconds.")
        
        # --- 4. Create FAISS index ---
        def create_faiss_index(embeddings):
            dim = embeddings.shape[1]
            index = faiss.IndexFlatIP(dim)
            index.add(embeddings)
            return index
        
        index = create_faiss_index(embeddings)
        
        # --- 5. Define retrieval functions ---
        def search_pdf(query, top_k=6):
            if index.ntotal == 0:
                return []
            q_embed = model.encode([query], normalize_embeddings=True)
            q_embed = np.array(q_embed).astype("float32")
            distances, indices = index.search(q_embed, top_k)
            results = []
            for i in indices[0]:
                if i == -1:
                    continue
                results.append({**chunk_metadata[i], "index": int(i)})
            return results
        
        # --- 6. Filtering very similar chunks ---
        def filter_redundant_chunks(results):
            idxs = [r['index'] for r in results]
            selected_embeds = embeddings[idxs]
            keep = []
            for i, emb in enumerate(selected_embeds):
                redundant = False
                for j in keep:
                    sim = cosine_similarity([emb], [selected_embeds[j]])[0][0]
                    if sim > 0.95:
                        redundant = True
                        break
                if not redundant:
                    keep.append(i)
            filtered = [results[i] for i in keep]
            return filtered
        
        # --- 7. Showing References ---
        def highlight_pdf_sections_and_preview(results, output_folder=None):
            if output_folder is None:
                output_folder = tempfile.mkdtemp(prefix="highlighted_pages_")
            else:
                os.makedirs(output_folder, exist_ok=True)
            doc = fitz.open(self.pdf_path)
            highlighted_files = []
            pages_done = set()
            produced_images = []
            for r in results:
                page_num = r['page'] - 1
                if page_num < 0 or page_num >= doc.page_count:
                    continue
                page = doc.load_page(page_num)
                text = r['text'].strip()
                hits = page.search_for(text)
                if not hits:
                    candidate = text.split('\n')[0]
                    if len(candidate) > 20:
                        hits = page.search_for(candidate)
                if not hits:
                    candidate = text[:120].strip()
                    if len(candidate) > 10:
                        hits = page.search_for(candidate)
                for rect in hits:
                    annot = page.add_highlight_annot(rect)
                    annot.set_colors(stroke=(1, 1, 0))
                    annot.update()
                if page_num not in pages_done:
                    pix = page.get_pixmap(matrix=fitz.Matrix(2, 2))
                    out_path = os.path.join(output_folder, f"page_{page_num + 1}.png")
                    pix.save(out_path)
                    produced_images.append(out_path)
                    pages_done.add(page_num)
            doc.close()
            if produced_images:
                cols = st.columns(len(produced_images))
                for col, img_path in zip(cols, produced_images):
                    col.image(img_path, caption=f"Page {Path(img_path).stem.split('_')[-1]}")
            return produced_images
        
        # Key objects as instance attributes
        self.model = model
        self.index = index
        self.chunks = chunks
        self.chunk_metadata = chunk_metadata
        self.embeddings = embeddings
        self.highlight_pdf_sections_and_preview = highlight_pdf_sections_and_preview
        self.search_pdf = search_pdf
        self.filter_redundant_chunks = filter_redundant_chunks

    def query(self, question, preview=True):
        results = []
        start_time = time.time()
        try:
            # --- 1) retrieve and filter ---
            results = self.search_pdf(question, top_k=6)
            results = self.filter_redundant_chunks(results)

            if not results:
                QUERY_COUNTER.labels(status="empty").inc()
                QUERY_LATENCY.labels(status="empty").observe(time.time() - start_time)
                return "No relevant passages found in the PDF."

            st.write("\n--- 📜 Top Retrieved Chunks ---")
            for i, r in enumerate(results, 1):
                st.write(f"\n[{i}] Page {r['page']}")
                st.write(" ".join(r['text'].split()[:100]) + "...")
            
            # --- 2) order by page and build context (truncate by words) ---
            ordered = sorted(results, key=lambda x: x['page'])
            meta_context = "\n\n".join([f"[Page {r['page']}] {r['text']}" for r in ordered])

            # keep at most max_words words from the combined context
            max_words = 1200
            meta_context = " ".join(meta_context.split()[:max_words])

            # try to avoid leaving a trailing incomplete sentence
            meta_context = re.sub(r'([.!?])[^.!?]*$', r'\1', meta_context)

            # --- 3) prompt for the LLM (use question variable consistently) ---
            prompt = f"""
            You are a historian-style research assistant.
            Read the following passages extracted from a textbook.
            Your task:
            1. First, directly answer the question asked.
            2. Then, explain **why** that answer is true using clear reasoning and evidence.
            3. Maintain logical or chronological order based on page numbers or timeline mentioned in context.
            4. Give the answer in **points** and mention the [Page x] numbers where possible.
            Please keep your answer concise (under 500 tokens) while preserving reasoning quality.

            Question:
            {question}

            Context:
            {meta_context}
            """
            st.write("\n🧠 Generating reasoned answer...\n")

            # --- 4) call LLM (replace `client` with your configured API client) ---
            
            response = client.chat.completions.create(
                model="gpt-4o-mini",
                messages=[{"role": "user", "content": prompt}],
                max_tokens=600,
                temperature=0.3
            )
            answer_text = response.choices[0].message.content.strip()

            duration = time.time() - start_time
            QUERY_COUNTER.labels(status="success").inc()
            QUERY_LATENCY.labels(status="success").observe(duration)

        except Exception as e:
            duration = time.time() - start_time
            QUERY_COUNTER.labels(status="error").inc()
            QUERY_LATENCY.labels(status="error").observe(duration)

            print("⚠️ API Error:", e)
            answer_text = "Sorry, I couldn't generate an answer due to an API error."

        # OPTIONAL: Ask if user wants to view highlighted pages
        if preview and results:
            st.write("\nGenerating highlighted preview...")
            self.highlight_pdf_sections_and_preview(results)
        return answer_text