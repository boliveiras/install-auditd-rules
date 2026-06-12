# install-auditd-rules

Instalador multi-distro para o **Linux Audit Daemon (auditd)** que aplica um
*ruleset* de auditoria de melhores práticas em hosts Linux.

---

## 📌 O que é este projeto?

`install-auditd-rules` é um script Bash, idempotente e **auto-contido** (um
único arquivo portável), que automatiza a instalação e a configuração de
auditoria de um host Linux:

1. Verifica privilégios e identifica a distribuição/gerenciador de pacotes.
2. Instala o `auditd` caso ainda não esteja presente.
3. Garante que o serviço esteja **ativo e habilitado no boot**.
4. **Substitui o ruleset padrão** (que vem vazio após a instalação) por um
   ruleset de melhores práticas em `/etc/audit/rules.d/audit.rules`.
5. Recarrega as regras (`augenrules --load`) e apresenta um resumo verificável.

O ruleset aplicado é o excelente **"Linux Audit Daemon - Best Practice
Configuration"**, de autoria de **Florian Roth / Nextron Systems**:

> 🔗 https://github.com/Neo23x0/auditd — © Florian Roth / Nextron Systems,
> licenciado sob Apache License 2.0.

### Como o ruleset é obtido

Para sempre aplicar a versão mais recente, o script segue esta ordem:

1. **Download** da versão mais atual diretamente do repositório oficial
   (via `curl`/`wget`) — assim acompanha eventuais atualizações do autor;
2. Se o download falhar (host sem rede, ou com a flag `--offline`), usa uma
   **cópia auto-contida embutida no próprio script** (fallback offline).

Dessa forma há **sempre** um ruleset válido para aplicar, mesmo em hosts
isolados. A cópia embutida é redistribuída **sem modificações**, com o
cabeçalho e a atribuição originais preservados. Todos os créditos do ruleset
pertencem ao autor original.

---

## 🎯 Para que ele serve?

- Padronizar a coleta de telemetria de segurança (Linux audit) em frota
  heterogênea, com um único script.
- Cumprir requisitos de **hardening / compliance** (CIS, PCI-DSS, ISO 27001),
  que exigem auditoria de eventos sensíveis: alterações em contas, sudoers,
  módulos de kernel, execução de binários suspeitos, etc.
- Provisionar auditoria de forma **reproduzível e auditável**, útil para times
  de **Blue/Purple Team** e administradores de sistemas.

---

## ✅ Compatibilidade

| Família           | Gerenciador | Pacote auditd            |
|-------------------|-------------|--------------------------|
| Debian / Ubuntu   | `apt`       | `auditd audispd-plugins` |
| RHEL / CentOS / Rocky / Alma / Fedora | `dnf` / `yum` | `audit` |
| openSUSE / SLES   | `zypper`    | `audit`                  |
| Arch              | `pacman`    | `audit`                  |
| Alpine (best effort) | `apk`    | `audit`                  |

Detecta automaticamente `systemd`, com *fallback* para `service`/`OpenRC`.
Requer **Bash 4+** e privilégios de **root**.

---

## 🚀 Como utilizar?

### 1. Tornar o script executável

```bash
chmod +x install-auditd-rules.sh
```

### 2. Execução padrão (baixa o template mais recente e aplica)

```bash
sudo ./install-auditd-rules.sh
```

### 3. Forçar uso da cópia embutida (sem rede)

```bash
sudo ./install-auditd-rules.sh --offline
```

### 4. Simulação (não altera nada no sistema)

```bash
sudo ./install-auditd-rules.sh --dry-run
```

### 5. Usar um ruleset customizado e travar as regras

```bash
sudo ./install-auditd-rules.sh --rules ./custom.rules --immutable
```

### Opções disponíveis

```
    --rules ARQUIVO   Usa este ruleset (ignora download e cópia embutida)
    --immutable       Torna as regras imutáveis (-e 2) até o próximo boot
    --offline         Não baixa; usa diretamente a cópia embutida
-y, --yes             Não pergunta confirmação em ações destrutivas
-n, --dry-run         Mostra o que faria, sem alterar o sistema
-h, --help            Ajuda
-V, --version         Versão
```

A URL de download do ruleset pode ser alterada pela variável de ambiente
`RULES_URL`.

### 5. Verificar o resultado

```bash
auditctl -s                 # status do subsistema de auditoria
auditctl -l                 # regras carregadas no kernel
ausearch -k susp_activity   # busca por eventos de uma key específica
```

---

## 🔒 Segurança e idempotência

- **Backups automáticos**: o `/etc/audit/rules.d/audit.rules` existente (o
  arquivo padrão e vazio do auditd) é copiado com sufixo `.bak-<timestamp>`
  antes de ser substituído.
- **Idempotente**: re-execuções são seguras.
- **Modo estrito**: `set -Eeuo pipefail` + *trap* de erro com número da linha.
- **`--dry-run`**: permite revisar todas as ações antes de aplicá-las.
- **`--immutable`**: opcional, adiciona `-e 2` para travar as regras até o
  próximo boot (útil em produção; deixe desligado durante testes).

---

## 📁 Estrutura do projeto

```
install-auditd-rules/
├── install-auditd-rules.sh   # instalador auto-contido (ruleset embutido)
├── README.md                 # este arquivo
├── LICENSE                   # Apache License 2.0
└── NOTICE                    # atribuições de terceiros
```

> O ruleset de Florian Roth não é mais um arquivo separado: ele é baixado em
> tempo de execução e também fica embutido em `install-auditd-rules.sh` como
> fallback (função `print_embedded_rules`).

---

## 📝 Licença

Este projeto é licenciado sob a **Apache License 2.0** — veja
[`LICENSE`](LICENSE) e [`NOTICE`](NOTICE).

O ruleset aplicado (baixado e também embutido no script como fallback) é de
autoria de **Florian Roth / Nextron Systems**
(https://github.com/Neo23x0/auditd), também sob Apache License 2.0, e é
redistribuído **sem modificações**.
