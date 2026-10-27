FROM python:3.13-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
RUN useradd --create-home --uid 10001 binderclip
COPY --chown=binderclip:binderclip . .
RUN mkdir -p /app/staticfiles && chown -R binderclip:binderclip /app/staticfiles
USER binderclip
EXPOSE 8000
CMD ["gunicorn", "binderclip.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "2", "--timeout", "60", "--access-logfile", "-"]
