# BEP Watch

Monitor local para procurar novas vagas no BEP e enviar alertas por email.

Funciona com PowerShell 7+ (`pwsh`) em Windows e Linux. Em Windows também corre com Windows PowerShell, mas em Linux/CachyOS deves instalar `powershell-bin` ou `powershell` via AUR.

## Funcionalidades

- Pesquisa várias keywords no BEP.
- Guarda vagas já vistas num ficheiro JSON local.
- Envia email só quando aparecem vagas novas.
- Email em HTML, com vagas ordenadas por prioridade geográfica.
- Tenta converter o código público da vaga para link direto `Oferta_Detalhes.aspx?CodOferta=...`.
- Configuração sem passwords no ficheiro, usando variável de ambiente.

## Configuração

```bash
cp config.example.json config.json
```

Edita `config.json` com:

- `SearchTerms` e `IncludeTerms`
- email SMTP
- destinatários
- `SubjectPrefix`
- `DistrictPriority`

Nunca publiques o teu `config.json` real. O `.gitignore` já está preparado para o ignorar.

## Password SMTP

Usa uma app password. Para Gmail, normalmente é necessário ativar 2FA e criar uma app password.

Windows PowerShell:

```powershell
[Environment]::SetEnvironmentVariable("BEP_SMTP_PASSWORD", "app-password", "User")
```

Linux:

```bash
export BEP_SMTP_PASSWORD='app-password'
```

Para `systemd`, coloca a variável no ficheiro `.service` ou, melhor, usa um `EnvironmentFile` privado.

## Primeira execução

Marca as vagas atuais como já vistas, sem enviar emails antigos:

```bash
pwsh -NoProfile -File ./bep-watch.ps1 -ConfigPath ./config.json -Prime
```

## Teste

```bash
pwsh -NoProfile -File ./bep-watch.ps1 -ConfigPath ./config.json -DryRun
```

## Execução normal

```bash
pwsh -NoProfile -File ./bep-watch.ps1 -ConfigPath ./config.json
```

## Agendamento em CachyOS/Linux

Instala PowerShell:

```bash
paru -S powershell-bin
```

Copia os exemplos:

```bash
mkdir -p ~/.config/systemd/user
cp examples/bep-watch.service ~/.config/systemd/user/
cp examples/bep-watch.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now bep-watch.timer
```

Verifica o agendamento:

```bash
systemctl --user list-timers bep-watch.timer
```

Corre manualmente:

```bash
systemctl --user start bep-watch.service
```

## Agendamento em Windows

Usa o Programador de Tarefas com:

- Programa: `powershell.exe`
- Argumentos:

```text
-ExecutionPolicy Bypass -File "C:\path\to\bep-watch.ps1" -ConfigPath "C:\path\to\config.json"
```

## Notas para Linux

O programa não precisa de grandes mudanças para CachyOS. As diferenças principais são:

- usar `pwsh` em vez de `powershell.exe`;
- trocar Task Scheduler por `systemd timer` ou `cron`;
- configurar a app password por variável de ambiente;
- atualizar caminhos Windows para caminhos Linux no `config.json`, se usares `StatePath` absoluto.
