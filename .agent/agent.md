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

## Deployment Strategy
- **GitHub**:
    1. Initialize local Git repo.
    2. Add `.gitignore` to exclude large binaries and runtime logs.
    3. Commit all source code.
    4. Provide the USER with commands to push to their remote repository.
- **Vercel**:
    - **API**: Host `src/server.js` as a Vercel Function (mapping via `vercel.json`).
    - **Frontend**: Host the Flutter Web build.
    - **Build Choice**: 
        - Option A: Build Flutter Web locally and commit `flutter_app/build/web` (Reliable, fast deploy).
        - Option B: Automated build on Vercel/GitHub (Requires Flutter SDK setup in CI).

## Change Log
- **2026-04-13 (c)**: Researched Vercel monorepo deployment for Flutter + Node.
- **2026-04-13 (b)**: Initialized `.agent/agent.md` and preparing for Vercel/GitHub deployment.
