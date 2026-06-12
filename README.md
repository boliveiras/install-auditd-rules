# install-auditd-rules

Instala o `auditd` em qualquer distro Linux e troca o ruleset padrão (que vem
vazio) por um conjunto de regras de auditoria de verdade, baseado no excelente
template de [Florian Roth / Nextron Systems](https://github.com/Neo23x0/auditd).

## Uso

```bash
chmod +x install-auditd-rules.sh
sudo ./install-auditd-rules.sh
```

Ele instala o `auditd`, garante que o serviço suba no boot, aplica o ruleset e
recarrega as regras. Antes de substituir o `audit.rules` existente, faz um
backup com timestamp.

O ruleset é baixado sempre na versão mais recente do repositório oficial. Sem
internet? O script já traz uma cópia embutida e usa ela automaticamente.

## Opções

```
--rules ARQUIVO   Usa um ruleset seu (ignora download e cópia embutida)
--immutable       Trava as regras (-e 2) até o próximo boot
--offline         Não baixa nada; usa a cópia embutida
-y, --yes         Não pergunta nada
-n, --dry-run     Mostra o que faria, sem tocar no sistema
-h, --help        Ajuda
-V, --version     Versão
```

Exemplos:

```bash
sudo ./install-auditd-rules.sh --dry-run     # simular
sudo ./install-auditd-rules.sh --offline     # sem rede
sudo ./install-auditd-rules.sh --immutable   # travar em produção
```

## Distros

Debian/Ubuntu/Kali, RHEL/CentOS/Rocky/Alma/Fedora, openSUSE/SLES, Arch e
Alpine. Precisa de root e Bash 4+.

## Conferir

```bash
sudo auditctl -s          # status (enabled deve ser 1)
sudo auditctl -l | wc -l  # quantas regras carregaram
sudo ausearch -k susp_activity --start recent
```

## Créditos & licença

O ruleset é de [Florian Roth / Nextron Systems](https://github.com/Neo23x0/auditd),
sob Apache 2.0, redistribuído sem modificações. Todo o crédito das regras é dele.

Este projeto também é Apache 2.0. Veja [LICENSE](LICENSE) e [NOTICE](NOTICE).
