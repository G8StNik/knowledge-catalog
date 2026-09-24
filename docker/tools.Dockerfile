FROM python:3.12-slim
WORKDIR /workspace
COPY pyproject.toml README.md ./
COPY packages ./packages
RUN python -m pip install --no-cache-dir --upgrade pip==26.2.1 \
    && python -m pip install --no-cache-dir -e '.[test]'
COPY database ./database
COPY tests ./tests
CMD ["python", "-m", "kc.migrate"]
