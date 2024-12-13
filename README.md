# pbsladek blog

## Running locally

To test locally, run the following in your terminal:

1. `bundle install`
2. `bundle exec jekyll serve`
3. Open your browser to `localhost:4000`

Uses [Github Pages](https://pages.github.com/) and [jglovier/resume-template](https://github.com/jglovier/resume-template)

## Install Ruby

```bash
# Install ruby with openssl@3 using chruby to manage versions for M1 mac
ruby-install ruby -- --with-openssl-dir=$(brew --prefix openssl@3)

# Verify Install
ruby -rrbconfig -e 'puts RbConfig::CONFIG["CXX"]'
```
