# Claude Code Config

Configurações portáteis do Claude Code para migração entre máquinas.

## Estrutura

```
~/.claude/
├── CLAUDE.md              # Prompt global (Tech Lead orchestrator)
├── settings.json          # Configurações do Claude Code
├── settings.local.json    # Permissões locais (não versionado por padrão)
├── agents/                # Agentes customizados (Agent Teams)
│   ├── frontend-senior-developer.md
│   ├── frontend-test-engineer.md
│   ├── nodejs-test-engineer.md
│   ├── python-junior-developer.md
│   ├── python-mid-developer.md
│   ├── python-senior-developer.md
│   ├── python-test-engineer.md
│   ├── senior-analyst.md
│   └── sysadmin-engineer.md
└── memories/              # Auto-memory do Claude Code
```

## O que cada arquivo faz

### CLAUDE.md

Prompt global que transforma o Claude em um **Tech Lead orquestrador**. Ele nunca executa tarefas diretamente — analisa o pedido, classifica o domínio e delega para o agente especializado via Agent Teams.

Regras principais:
- Classificação por extensão de arquivo (`.py` → Python agent, `.tsx` → Frontend agent, etc.)
- Avaliação de risco (low/medium/high) antes de delegar
- Integração com Obsidian para memória persistente entre sessões
- Proibição de deploy por agentes (só preparam artefatos)

### settings.json

Configurações globais do Claude Code. Atualmente:
- `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` — habilita Agent Teams (necessário para o sistema de delegação funcionar)
- `teammateMode: "tmux"` — teammates rodam em painéis tmux

### settings.local.json

Permissões de ferramentas específicas da máquina. Pode variar entre máquinas, mas está versionado para servir de referência.

### agents/

Cada arquivo `.md` define um agente especializado com:
- Frontmatter YAML (nome, modelo, descrição)
- System prompt com instruções específicas do domínio
- Template de memória Obsidian para registrar tarefas completadas

Os agentes são invocados automaticamente pelo CLAUDE.md quando uma tarefa é delegada.

### memories/

Diretório de auto-memory do Claude Code. Armazena contexto persistente sobre o usuário, feedback, projetos e referências entre conversas.

## Dependências

| Dependência | Obrigatória | Para que serve |
|---|---|---|
| [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) | Sim | Runtime que lê estes arquivos |
| **tmux** | Sim | Necessário para `teammateMode: "tmux"` — cada agente roda em um painel tmux |
| **Obsidian** (com iCloud) | Não* | Memória persistente entre sessões. Sem ele, os agentes não salvam/leem histórico de tarefas |

\* O sistema funciona sem Obsidian, mas perde a capacidade de memória entre sessões via Obsidian. O auto-memory do Claude Code (`memories/`) funciona independentemente.

## Instalação em uma nova máquina

```bash
# 1. Instalar Claude Code
npm install -g @anthropic-ai/claude-code

# 2. Instalar tmux (necessário para Agent Teams)
brew install tmux   # macOS
# sudo apt install tmux   # Linux

# 3. Clonar este repo
git clone <repo-url> ~/.claude

# 4. (Opcional) Configurar Obsidian com iCloud sync
# O path esperado pelos agentes:
# ~/Library/Mobile Documents/iCloud~md~obsidian/Documents/name/PROJECTS/
```

## O que NÃO está versionado

Tudo que é estado local e efêmero:
- `projects/` — histórico de conversas por projeto
- `sessions/` — sessões ativas
- `cache/`, `paste-cache/` — caches temporários
- `history.jsonl` — histórico de comandos
- `todos/`, `tasks/`, `plans/` — estado de tarefas em andamento
- `debug/`, `telemetry/`, `statsig/` — logs e telemetria
- `ide/`, `plugins/`, `shell-snapshots/` — estado do IDE

Esses diretórios são recriados automaticamente pelo Claude Code.
