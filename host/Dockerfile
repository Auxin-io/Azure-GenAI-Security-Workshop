# The notebook host attendees connect to.
#
# The point of running the notebooks here rather than in Colab: this container carries a
# user-assigned managed identity, so there is no secret to hand out, none to leak, and none to
# forget to revoke. DefaultAzureCredential picks the identity up from the instance metadata
# endpoint, and the notebooks run completely unchanged.
FROM python:3.11-slim

# git is needed because the startup script pulls the workshop content at boot rather than baking
# it in - so a content fix does not require rebuilding and redeploying the image.
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workshop

RUN pip install --no-cache-dir \
      jupyterlab==4.2.5 \
      azure-identity>=1.17 \
      "azure-ai-projects>=2" \
      "azure-ai-agents>=1.1" \
      pyyaml

# Non-root. The managed identity is granted through the platform, not through the filesystem,
# so nothing here needs elevated rights.
RUN useradd -m -u 1000 jovyan && chown -R jovyan /workshop
USER jovyan

COPY --chown=jovyan start.sh /usr/local/bin/start.sh
EXPOSE 8888
CMD ["bash", "/usr/local/bin/start.sh"]
