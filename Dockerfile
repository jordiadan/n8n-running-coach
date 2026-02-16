FROM n8nio/n8n:2.7.5
WORKDIR /home/node/.n8n
COPY workflows/running_coach_workflow.json /opt/workflows/running_coach_workflow.json
ENV DB_TYPE=postgres
ENV GENERIC_TIMEZONE=Europe/Madrid
ENV N8N_BASIC_AUTH_ACTIVE=true
ENV N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER}
ENV N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}
EXPOSE 5678
