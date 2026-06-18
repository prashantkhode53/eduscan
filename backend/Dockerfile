# EduScan backend — Node.js + TypeScript
# Build: docker build -t eduscan-backend ./backend
# Coolify: set Build Pack = Dockerfile, Base Directory = /backend

FROM node:20-alpine

WORKDIR /app

# Install deps first for better layer caching.
# package.json keeps typescript + @types under "dependencies",
# so a plain `npm install` is enough to build.
COPY package*.json ./
RUN npm install

# Copy source and compile TypeScript -> dist/
COPY . .
RUN npm run build

# Backend listens on PORT (default 3000); index.ts binds 0.0.0.0.
EXPOSE 3000

CMD ["npm", "start"]
