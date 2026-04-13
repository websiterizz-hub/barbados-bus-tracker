# Agent Context — Barbados Bus Tracker

## Project Overview
This is a bus tracking application for Barbados. It consists of:
- **Flutter App** (`flutter_app/`): Mobile, Desktop, and Web UI.
- **Node.js API** (`src/server.js`): Backend that processes live transit data and serves the app.
- **Data Pipeline** (`scripts/`): Tools for building bus stop and route datasets.

## Current Goal
- [ ] Push to GitHub.
- [ ] Deploy to Vercel (Web + API).
- [ ] Maintain session continuity for other AI models.

## Key Files
- `AI_HANDOFF.md`: Detailed history of changes and build instructions.
- `package.json`: Root scripts for building and running the project.
- `src/server.js`: The entry point for the API and static file serving.
- `flutter_app/pubspec.yaml`: Flutter project configuration.

## Deployment Status
- [x] Initialized Git repository.
- [x] Created `.gitignore` (optimized for Vercel/GitHub).
- [x] Built Flutter Web app locally (`build/web` committed).
- [x] Created `vercel.json` and `api/index.js` for Vercel deployment.
- [x] Committed all source code and artifacts to local master branch.

## Final Steps for USER
1. Create an empty repository on GitHub.
2. Link local repo: `git remote add origin <URL>`
3. Push code: `git push -u origin master`
4. In Vercel, import the GitHub repository. It will auto-detect the configuration and deploy!

## Change Log
- **2026-04-13 (d)**: Completed local setup for Vercel and Git. Built Flutter Web and configured serverless entry point.
- **2026-04-13 (c)**: Researched Vercel monorepo deployment for Flutter + Node.
- **2026-04-13 (b)**: Initialized `.agent/agent.md` and preparing for Vercel/GitHub deployment.
