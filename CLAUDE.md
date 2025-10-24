# AI Battle Arena - Claude Code Guidelines

ETHGlobal Online 2025 - DeFi Battle Arena Project

## 🎯 Project Overview

This is a **fork** of the alphaEngine project adapted for the ETHGlobal Online 2025 hackathon. The project consists of a DeFi strategy builder with backend (FastAPI) and frontend (Next.js) components.

## 📂 Directory Mapping

**Current Structure → Original Reference:**

| Current Directory | Original Reference | Description |
|------------------|-------------------|-------------|
| `CiFHErTradeArena-BE/` | `/Users/consentsam/blockchain/alphaEngine/working-directory/alphaEngine-strategy/` | Backend (FastAPI + Python) |
| `CiFHErTradeArena-FE/` | `/Users/consentsam/blockchain/alphaEngine/working-directory/alphaEngine-frontend/` | Frontend (Next.js + React) |

## 🔗 Reference Documentation

When in doubt or encountering errors, **always refer to the original repositories** for context and solutions:

- **Backend Reference**: `/Users/consentsam/blockchain/alphaEngine/working-directory/alphaEngine-strategy/`
- **Frontend Reference**: `/Users/consentsam/blockchain/alphaEngine/working-directory/alphaEngine-frontend/`

## 🚀 Quick Start

### Starting Both Servers

```bash
# From working directory root
./start-servers.sh
```

This will:

1. Kill any existing processes on ports 8000 and 3000
2. Load backend environment variables from `CiFHErTradeArena-BE/.env`
3. Start backend on `http://0.0.0.0:8000`
4. Start frontend on `http://localhost:3000`

### Manual Server Start

**Backend (Terminal 1):**

```bash
cd CiFHErTradeArena-BE
.venv/bin/python src/main.py  # Port 8000
```

**Frontend (Terminal 2):**

```bash
cd CiFHErTradeArena-FE
bun run dev  # Port 3000
```

## 📦 Tech Stack

### Backend (CiFHErTradeArena-BE)

- **Language**: Python 3.11+
- **Framework**: FastAPI + Pydantic v2
- **Blockchain**: Web3.py for Ethereum interaction
- **Package Manager**: uv (NOT poetry)
- **Testing**: Pytest
- **Type Checking**: mypy (strict mode)
- **Linting**: Ruff

### Frontend (CiFHErTradeArena-FE)

- **Framework**: Next.js 15 (App Router)
- **UI Library**: React 19
- **Language**: TypeScript 5
- **Components**: shadcn/ui
- **Styling**: Tailwind CSS 3.4
- **Package Manager**: Bun
- **Icons**: Lucide React

## ⚠️ Critical Rules

### Backend

1. **ALWAYS use correct server startup:**

   ```bash
   # ✅ Correct
   .venv/bin/python src/main.py

   # ❌ Wrong
   python3 -m uvicorn src.main:app --reload
   ```

2. **ALWAYS use `uv` for package management:**

   ```bash
   uv sync                # Install dependencies
   uv add <package>       # Add new package
   ```

3. **ALWAYS include Python type hints (100% coverage)**

### Frontend

1. **ALWAYS use shadcn/ui for UI components** (never create custom primitives)
2. **ALWAYS use `bun` for package management** (never npm/yarn/pnpm)
3. **ALWAYS include TypeScript types**

## 🐛 Debugging Workflow

When encountering errors or issues:

### Step 1: Check Current Codebase

- Review the error message and stack trace
- Check relevant files in current repository

### Step 2: Consult Original Reference

- Navigate to the original repository at `/Users/consentsam/blockchain/alphaEngine/working-directory/`
- Check if similar code exists and how it's implemented
- Review CLAUDE.md files in original repos for guidance

### Step 3: Apply Fixes

- Apply solutions from original reference
- Adapt to current directory structure if needed
- Test thoroughly

## 📋 Environment Setup

### Backend Environment Variables

Create `CiFHErTradeArena-BE/.env` based on `.env.example`:

```bash
cd CiFHErTradeArena-BE
cp .env.example .env
# Edit .env with your configuration
```

### Frontend Environment Variables

Frontend already has `.env` and `.env.local` files configured.

## 🔄 Development Workflow

### Adding New Dependencies

**Backend:**

```bash
cd CiFHErTradeArena-BE
uv add <package>           # Production
uv add --dev <package>     # Development
```

**Frontend:**

```bash
cd CiFHErTradeArena-FE
bun add <package>           # Production
bun add -d <package>        # Development
```

### Running Tests

**Backend:**

```bash
cd CiFHErTradeArena-BE
uv run pytest                    # All tests
uv run pytest tests/unit/        # Unit tests only
```

**Frontend:**

```bash
cd CiFHErTradeArena-FE
bun test                         # Run tests
```

### Code Quality Checks

**Backend:**

```bash
cd CiFHErTradeArena-BE
uv run ruff check .          # Linting
uv run mypy src/             # Type checking
uv run pre-commit run --all-files
```

**Frontend:**

```bash
cd CiFHErTradeArena-FE
bun run lint                 # ESLint
bun run type-check           # TypeScript check
```

## ⛔ CRITICAL: Pre-Commit Hooks - Zero Tolerance

**ABSOLUTE RULE**: NEVER bypass pre-commit hooks under ANY circumstances.

**FORBIDDEN Commands:**

```bash
# ❌ NEVER USE THESE
git commit --no-verify -m "..."
git commit -n -m "..."
SKIP=mypy git commit -m "..."
SKIP=ruff git commit -m "..."
```

**ONLY ACCEPTABLE Workflow:**

```bash
# ✅ CORRECT - Fix ALL errors, then commit normally
git add <files>
git commit -m "..."
# All hooks run and ALL must pass
```

If pre-commit fails:

1. Read ALL error messages carefully
2. Fix ALL reported issues
3. Stage the fixes: `git add <files>`
4. Commit again normally
5. NEVER use --no-verify or SKIP

## 📚 Additional Resources

### Original Project Documentation

**Backend (alphaEngine-strategy):**

- CLAUDE.md: `/Users/consentsam/blockchain/alphaEngine/working-directory/alphaEngine-strategy/CLAUDE.md`
- Context files: `/Users/consentsam/blockchain/alphaEngine/working-directory/alphaEngine-strategy/local-working-project-folder/context/`

**Frontend (alphaEngine-frontend):**

- CLAUDE.md: `/Users/consentsam/blockchain/alphaEngine/working-directory/alphaEngine-frontend/CLAUDE.md`
- Context files: `/Users/consentsam/blockchain/alphaEngine/working-directory/alphaEngine-frontend/local-working-project-folder/context/`

### Current Project Documentation

**Backend:**

- CLAUDE.md: `./CiFHErTradeArena-BE/CLAUDE.md`
- AGENTS.md: `./CiFHErTradeArena-BE/AGENTS.md`

**Frontend:**

- CLAUDE.md: `./CiFHErTradeArena-FE/CLAUDE.md`
- AGENTS.md: `./CiFHErTradeArena-FE/AGENTS.md`

## 🚨 Common Pitfalls

### Things to Avoid

1. **Using wrong directory names in commands:**

   ```bash
   # ❌ Wrong
   cd alphaEngine-strategy

   # ✅ Correct
   cd CiFHErTradeArena-BE
   ```

2. **Using wrong package manager:**

   ```bash
   # ❌ Wrong (Backend)
   poetry install

   # ✅ Correct
   uv sync
   ```

3. **Forgetting environment variables:**

   ```bash
   # Backend requires .env file for API keys, RPC URLs, etc.
   # Make sure CiFHErTradeArena-BE/.env exists before starting
   ```

## 🎯 ETHGlobal Hackathon Notes

This project is being developed for **ETHGlobal Online 2025**. Key focus areas:

- DeFi strategy simulation and execution
- Battle arena mechanics for competing strategies
- Real-time strategy validation
- User-friendly frontend for strategy building

## 📞 Support

When encountering issues:

1. Check current repository documentation
2. Consult original alphaEngine repository for reference
3. Review error logs in respective directories
4. Check backend logs in `CiFHErTradeArena-BE/`
5. Check frontend console in browser DevTools

---

*Last updated: October 24, 2025*
