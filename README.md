# huisam.github.io

Personal blog built with the [Chirpy](https://github.com/cotes2020/jekyll-theme-chirpy) Jekyll theme.

## Deployment

The site is built and deployed by GitHub Actions (`.github/workflows/pages-deploy.yml`).

> **One-time setup:** In the repository **Settings → Pages**, set **Source** to
> **GitHub Actions**. Chirpy uses plugins that the default GitHub Pages build
> does not allow, so it must be built via Actions rather than the classic
> "Deploy from a branch" flow.

Every push to `main` triggers a build and deploy.

## Writing a post

Add a Markdown file to `_posts/` named `YYYY-MM-DD-title.md` with front matter:

```yaml
---
title: "Post title"
date: 2026-07-28 20:07:00 +0900
categories: [Developer, Spring]
tags: [spring, kotlin]
---
```

Post images live under `assets/images/` and are referenced from the site root,
e.g. `![alt](/assets/images/2026-07-28/example.png)`.

## Running locally

Requires Ruby 3.x and Bundler:

```bash
bundle install
bundle exec jekyll serve
```
