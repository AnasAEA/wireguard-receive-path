# docs/

Project documentation, organized by topic.

| Folder | Contents |
|--------|----------|
| [`cloudlab/`](cloudlab/) | **Current phase.** CloudLab measurement: strategy (`CLOUDLAB_MEASUREMENT_PLAN`), operational runbook (`CLOUDLAB_EXPERIMENTS_PLAN`), lab log/findings (`CLOUDLAB_EXPERIMENTS_LOG`), and the live hands-on walkthrough (`CLOUDLAB_NEXT_STEPS`). |
| [`study/`](study/) | Source & pipeline analysis: `CODE_STUDY_*`, `PIPELINE_*`, diagram specs, `ANDRE_SOLUTION_PROPOSAL`, EoI proof, `IO_URING_REFERENCE`. |
| [`defense/`](defense/) | Defense + subject presentations: slides (`SLIDES_*`), speaker notes, Q&A prep, `build_pptx.py`, submitted report PDF. |
| [`meetings/`](meetings/) | Supervisor comms: meeting notes & prep, replies, progress reports (`RAPPORT_AVANCEMENT`, `POINT_ALAIN`, `REUNION_ALAIN`). |
| [`experiments/`](experiments/) | M1 experiment runbooks (`EXPERIMENTS_*`, `RUN_*`, compilation/test guide). |

Rendered PDFs sit next to their `.md` source where they exist; they are
git-ignored (regenerate from the Markdown). The runnable testbed scripts live in
[`../scripts/cloudlab/`](../scripts/cloudlab/).
