# Fleet or session, per repo

AS_OF 2026-10-22T08:00:00Z. Rule: `fleet <=> planned units closed 90d (done waves + fleet phase merges) >= 10 and commits_per_week >= 25`. Incident load is shown, not decisive.

| Repo | Root | Class | Commits 90 d | /week | Waves closed 90 d | Active waves | Items 30 d | Escalated 30 d | Runtime units |
|-|-|-|-|-|-|-|-|-|-|
| basalt-ui | SourceRoot | fleet | 1884 | 146.5 | 49 | 3 | 0 | 0 | 1 |
| argo | SourceRoot | fleet | 1140 | 88.7 | 53 | 0 | 1 | 0 | 2 |
| weatherorb | SourceRoot | fleet | 984 | 76.5 | 63 | 2 | 96 | 26 | 13 |
| shutterflow | SourceRoot | fleet | 818 | 63.6 | 286 | 0 | 1 | 0 | 4 |
| dotfiles | SourceRoot | fleet | 558 | 43.4 | 45 | 1 | 15 | 6 | 24 |
| warden | SourceRoot | fleet | 528 | 41.1 | 12 | 1 | 55 | 13 | 5 |
| brain | SourceRoot | session | 493 | 38.3 | 0 | 0 | 1 | 1 | 0 |
| hermes-agent | SourceRoot | session | 306 | 23.8 | 4 | 0 | 33 | 13 | 5 |
| research-gateway | SourceRoot | session | 269 | 20.9 | 11 | 0 | 13 | 3 | 3 |
| agent-gateway | SourceRoot | session | 258 | 20.1 | 17 | 1 | 16 | 5 | 0 |
| vps | SourceRoot | session | 179 | 13.9 | 0 | 0 | 11 | 9 | 15 |
| linewatch | SourceRoot | session | 141 | 11.0 | 11 | 0 | 0 | 0 | 3 |
| epos.student-enrolment | IuRoot | session | 140 | 10.9 | 0 | 0 | 0 | 0 | 0 |
| rb | SourceRoot | session | 125 | 9.7 | 8 | 0 | 3 | 0 | 0 |
| modelpick | SourceRoot | session | 113 | 8.8 | 0 | 0 | 1 | 0 | 2 |
| homelab-private | SourceRoot | session | 107 | 8.3 | 0 | 0 | 2 | 1 | 1 |
| email-gateway | SourceRoot | session | 102 | 7.9 | 19 | 0 | 2 | 1 | 1 |
| homelab | SourceRoot | session | 94 | 7.3 | 0 | 0 | 25 | 13 | 25 |
| prometheus-epx | IuRoot | session | 92 | 7.2 | 0 | 0 | 0 | 0 | 0 |
| prometheus-scripts | IuRoot | session | 92 | 7.2 | 0 | 0 | 0 | 0 | 0 |
| dotfiles-private | SourceRoot | session | 88 | 6.8 | 0 | 0 | 0 | 0 | 0 |
| audio-gateway | SourceRoot | session | 82 | 6.4 | 0 | 0 | 2 | 0 | 2 |
| epos-orchestrator-frontend | IuRoot | session | 67 | 5.2 | 0 | 0 | 0 | 0 | 0 |
| basalt-ui-obsidian | SourceRoot | session | 64 | 5.0 | 7 | 0 | 0 | 0 | 0 |
| epos_fe.booking | IuRoot | session | 56 | 4.4 | 0 | 0 | 0 | 0 | 0 |
| rollhook | SourceRoot | session | 54 | 4.2 | 5 | 0 | 2 | 2 | 2 |
| prometheus-stack | IuRoot | session | 52 | 4.0 | 8 | 0 | 0 | 0 | 0 |
| usage-tracker | SourceRoot | session | 48 | 3.7 | 0 | 0 | 1 | 1 | 1 |
| image-gateway | SourceRoot | session | 45 | 3.5 | 0 | 0 | 1 | 1 | 1 |
| sy-serendipity | SourceRoot | session | 42 | 3.3 | 0 | 0 | 0 | 0 | 0 |
| epos.study-progress | IuRoot | session | 39 | 3.0 | 0 | 0 | 0 | 0 | 0 |
| epos.exam | IuRoot | session | 36 | 2.8 | 0 | 0 | 0 | 0 | 0 |
| epos_fe.academic-profile | IuRoot | session | 31 | 2.4 | 0 | 0 | 0 | 0 | 0 |
| tinycast-extensions | SourceRoot | session | 25 | 1.9 | 0 | 0 | 0 | 0 | 0 |
| jkrumm.com | SourceRoot | session | 23 | 1.8 | 0 | 0 | 0 | 0 | 1 |
| epos.finance-bridge | IuRoot | session | 20 | 1.6 | 0 | 0 | 0 | 0 | 0 |
| epos-customers-frontend | IuRoot | session | 19 | 1.5 | 0 | 0 | 0 | 0 | 0 |
| free-planning-poker | SourceRoot | session | 16 | 1.2 | 0 | 0 | 5 | 3 | 4 |
| rollhook-action | SourceRoot | session | 12 | 0.9 | 0 | 0 | 0 | 0 | 0 |
| dispatch-scratch | SourceRoot | session | 9 | 0.7 | 0 | 0 | 0 | 0 | 0 |
| king-smith-walkingpad-mac | SourceRoot | session | 9 | 0.7 | 0 | 0 | 0 | 0 | 1 |
| basalt-expr-trial-v1 | SourceRoot | session | 4 | 0.3 | 0 | 1 | 0 | 0 | 0 |
| epos_fe.customer-navigation | IuRoot | session | 4 | 0.3 | 0 | 0 | 0 | 0 | 0 |
| basalt-expr-trial | SourceRoot | session | 2 | 0.2 | 0 | 1 | 0 | 0 | 0 |
| kobo-mods | SourceRoot | session | 2 | 0.2 | 0 | 0 | 0 | 0 | 0 |
| epos-data-analytics | IuRoot | session | 1 | 0.1 | 0 | 0 | 0 | 0 | 0 |
| cfn-kafka | IuRoot | session | 0 | 0.0 | 0 | 0 | 0 | 0 | 0 |
| epos.crm-bridge | IuRoot | session | 0 | 0.0 | 0 | 0 | 0 | 0 | 0 |
| epos.dam | IuRoot | session | 0 | 0.0 | 0 | 0 | 0 | 0 | 0 |
| epos.iam | IuRoot | session | 0 | 0.0 | 0 | 0 | 0 | 0 | 0 |
| epos_fe.spa-orchestrator | IuRoot | session | 0 | 0.0 | 0 | 0 | 0 | 0 | 0 |
| prometheus-feuer-agent | IuRoot | session | 0 | 0.0 | 0 | 0 | 0 | 0 | 0 |
| terraform-monitoring | IuRoot | session | 0 | 0.0 | 0 | 0 | 0 | 0 | 0 |
