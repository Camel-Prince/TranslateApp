#!/usr/bin/env python3
"""
paper_translate.py — CS Paper full-text extraction, translation & term extraction.

Usage:
    python paper_translate.py /path/to/paper.pdf [--output-dir ~/.translate/papers]

Output:
    <output_dir>/<hash>_translated.md   — 全文翻译
    <output_dir>/<hash>_context.json    — 术语表 + 语境信息
"""

import sys
import os
import json
import hashlib
import re
import time
import urllib.request
import urllib.error

# Try to import fitz (pymupdf)
try:
    import fitz  # pymupdf
except ImportError:
    print("ERROR: pymupdf not installed. Run: pip install pymupdf", file=sys.stderr)
    sys.exit(1)

API_ENDPOINT = "http://localhost:8765/v1/chat/completions"
API_KEY = "placeholder"
MODEL = "deepseek-chat"
MAX_CHUNK_CHARS = 3000  # chars per translation chunk


def extract_text_from_pdf(pdf_path: str) -> list[dict]:
    """Extract text from PDF, skipping figures/tables/references."""
    doc = fitz.open(pdf_path)
    paragraphs = []
    in_references = False

    for page_num in range(len(doc)):
        page = doc[page_num]
        blocks = page.get_text("blocks")  # (x0, y0, x1, y1, text, block_no, block_type)

        for block in blocks:
            block_type = block[6]  # 0=text, 1=image
            if block_type == 1:
                continue  # skip images

            text = block[4].strip()
            if not text:
                continue

            # Skip references section
            if re.match(r'^(References|Bibliography|REFERENCES)\s*$', text):
                in_references = True
                continue
            if in_references:
                continue

            # Skip figure/table captions
            if re.match(r'^(Figure|Fig\.|Table|TABLE)\s*\d', text, re.IGNORECASE):
                continue

            # Skip acknowledgments
            if re.match(r'^(Acknowledgments?|ACKNOWLEDGMENTS?)\s*$', text):
                continue

            # Skip lines that are mostly math/symbols (>60% non-alpha)
            alpha_ratio = sum(1 for c in text if c.isalpha()) / max(len(text), 1)
            if alpha_ratio < 0.3 and len(text) > 20:
                continue

            # Skip very short lines (likely headers/footers with page numbers)
            if len(text) < 10 and text.isdigit():
                continue

            paragraphs.append({
                "page": page_num + 1,
                "text": text
            })

    doc.close()

    # Reset references flag for next pass - merge short consecutive paragraphs
    merged = []
    buffer = ""
    for p in paragraphs:
        text = p["text"]
        # If line is short and doesn't end with period, it's likely a continuation
        if len(buffer) > 0 and len(text) < 100 and not buffer.endswith(('.', '。', '!', '?')):
            buffer += " " + text
        elif len(text) < 50 and not text.endswith(('.', '。', ':', '：')):
            if buffer:
                merged.append(buffer)
            buffer = text
        else:
            if buffer:
                merged.append(buffer + " " + text if len(buffer) < 80 else buffer)
                if len(buffer) >= 80:
                    merged.append(text)
                buffer = ""
            else:
                merged.append(text)

    if buffer:
        merged.append(buffer)

    return merged


def chunk_paragraphs(paragraphs: list[str], max_chars: int = MAX_CHUNK_CHARS) -> list[str]:
    """Split paragraphs into chunks suitable for API calls."""
    chunks = []
    current_chunk = ""

    for para in paragraphs:
        if len(current_chunk) + len(para) + 2 > max_chars:
            if current_chunk:
                chunks.append(current_chunk.strip())
            # If single paragraph exceeds limit, split it
            if len(para) > max_chars:
                words = para.split()
                sub_chunk = ""
                for word in words:
                    if len(sub_chunk) + len(word) + 1 > max_chars:
                        chunks.append(sub_chunk.strip())
                        sub_chunk = word
                    else:
                        sub_chunk += " " + word
                if sub_chunk:
                    current_chunk = sub_chunk
            else:
                current_chunk = para
        else:
            current_chunk += "\n\n" + para if current_chunk else para

    if current_chunk:
        chunks.append(current_chunk.strip())

    return chunks


def call_api(system_prompt: str, user_text: str, temperature: float = 0.3) -> str:
    """Call the local DeepSeek API."""
    body = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_text}
        ],
        "max_tokens": 4096,
        "stream": False,
        "temperature": temperature
    }

    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        API_ENDPOINT,
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {API_KEY}"
        }
    )

    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            result = json.loads(resp.read().decode("utf-8"))
            return result["choices"][0]["message"]["content"].strip()
    except urllib.error.URLError as e:
        print(f"  ⚠️ API error: {e}", file=sys.stderr)
        return ""
    except Exception as e:
        print(f"  ⚠️ Unexpected error: {e}", file=sys.stderr)
        return ""


def translate_chunk(chunk: str, chunk_idx: int, total: int) -> str:
    """Translate a single chunk of text."""
    system_prompt = """你是一个计算机科学/AI领域的专业翻译。将以下学术论文段落翻译为中文。

翻译原则：
1. 专业术语使用CS/AI领域的标准译法
2. 保留无需翻译的专有名词（如 GPT、BERT、ResNet、Adam、Transformer）
3. 保留公式和数学符号不翻译
4. 译文要自然流畅，符合中文学术表达习惯
5. 段落结构保持不变
6. 只输出翻译结果"""

    print(f"  📝 翻译 chunk {chunk_idx+1}/{total} ({len(chunk)} chars)...", file=sys.stderr)
    result = call_api(system_prompt, chunk)
    time.sleep(0.5)  # rate limiting
    return result


def extract_terms(full_text: str) -> dict:
    """Extract key CS/AI terms and their translations from the paper."""
    system_prompt = """分析以下CS/AI论文原文，提取其中的关键专业术语，并给出中文翻译。

要求：
1. 只提取该论文中重要的、有领域特定含义的术语（15-40个）
2. 包括：方法名、模型名、技术概念、度量指标等
3. 不要包含过于通用的词（如 "the", "method", "result"）
4. 返回严格的JSON格式，不要有其他文字

返回格式：
{"terms": {"English term": "中文翻译", "another term": "翻译"}}"""

    # Use first ~4000 chars of text for term extraction (enough for context)
    sample = full_text[:6000]
    print(f"  🔍 抽取关键术语...", file=sys.stderr)
    result = call_api(system_prompt, sample, temperature=0.2)

    # Parse JSON
    try:
        # Strip markdown code block if present
        if "```" in result:
            lines = result.split("\n")
            json_lines = [l for l in lines if not l.startswith("```")]
            result = "\n".join(json_lines)

        if "{" in result:
            start = result.index("{")
            end = result.rindex("}") + 1
            result = result[start:end]

        data = json.loads(result)
        return data.get("terms", data)
    except (json.JSONDecodeError, ValueError) as e:
        print(f"  ⚠️ Failed to parse terms JSON: {e}", file=sys.stderr)
        return {}


def process_paper(pdf_path: str, output_dir: str) -> dict:
    """Full pipeline: extract → translate → extract terms."""
    print(f"📄 Processing: {os.path.basename(pdf_path)}", file=sys.stderr)

    # Generate hash for output filenames
    with open(pdf_path, "rb") as f:
        paper_hash = hashlib.md5(f.read()[:10000]).hexdigest()[:10]

    # Step 1: Extract text
    print(f"  📖 Extracting text...", file=sys.stderr)
    paragraphs = extract_text_from_pdf(pdf_path)
    print(f"  ✅ Extracted {len(paragraphs)} paragraphs", file=sys.stderr)

    if not paragraphs:
        print("  ❌ No text extracted from PDF", file=sys.stderr)
        return {"error": "No text extracted"}

    full_text = "\n\n".join(paragraphs)

    # Step 2: Translate in chunks
    chunks = chunk_paragraphs(paragraphs)
    print(f"  📦 Split into {len(chunks)} chunks for translation", file=sys.stderr)

    translated_chunks = []
    for i, chunk in enumerate(chunks):
        translated = translate_chunk(chunk, i, len(chunks))
        if translated:
            translated_chunks.append(translated)
        else:
            translated_chunks.append(f"[翻译失败: chunk {i+1}]")

    translated_text = "\n\n".join(translated_chunks)

    # Step 3: Extract key terms
    terms = extract_terms(full_text)
    print(f"  ✅ Extracted {len(terms)} key terms", file=sys.stderr)

    # Step 4: Save outputs
    os.makedirs(output_dir, exist_ok=True)

    # Save translated text
    translated_path = os.path.join(output_dir, f"{paper_hash}_translated.md")
    with open(translated_path, "w", encoding="utf-8") as f:
        f.write(f"# 翻译: {os.path.basename(pdf_path)}\n\n")
        f.write(f"原文件: {pdf_path}\n")
        f.write(f"翻译时间: {time.strftime('%Y-%m-%d %H:%M:%S')}\n\n---\n\n")
        f.write(translated_text)

    # Save context (terms + metadata)
    context_path = os.path.join(output_dir, f"{paper_hash}_context.json")
    context_data = {
        "paper_hash": paper_hash,
        "paper_title": os.path.basename(pdf_path).replace(".pdf", ""),
        "paper_path": pdf_path,
        "terms": terms,
        "paragraph_count": len(paragraphs),
        "created_at": time.strftime('%Y-%m-%d %H:%M:%S')
    }
    with open(context_path, "w", encoding="utf-8") as f:
        json.dump(context_data, f, ensure_ascii=False, indent=2)

    print(f"\n✅ 完成!", file=sys.stderr)
    print(f"  📝 译文: {translated_path}", file=sys.stderr)
    print(f"  📋 语境: {context_path}", file=sys.stderr)

    # Output the context JSON to stdout (for Swift to read)
    print(json.dumps(context_data, ensure_ascii=False))

    return context_data


def main():
    if len(sys.argv) < 2:
        print("Usage: paper_translate.py <pdf_path> [--output-dir <dir>]", file=sys.stderr)
        sys.exit(1)

    pdf_path = sys.argv[1]
    if not os.path.exists(pdf_path):
        print(f"ERROR: File not found: {pdf_path}", file=sys.stderr)
        sys.exit(1)

    output_dir = os.path.expanduser("~/.translate/papers")
    if "--output-dir" in sys.argv:
        idx = sys.argv.index("--output-dir")
        if idx + 1 < len(sys.argv):
            output_dir = sys.argv[idx + 1]

    process_paper(pdf_path, output_dir)


if __name__ == "__main__":
    main()
