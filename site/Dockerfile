FROM node:26-slim
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install --omit=dev
COPY . .
ENV PORT=8787
EXPOSE 8787
VOLUME /app/data
CMD ["node", "server.js"]
