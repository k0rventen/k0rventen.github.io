# blog

src for my blog/site using [hugo](https://gohugo.io).

the src is in the main branch, and each commit triggers the rendering of the site in the gh-pages branch, on which Github Pages points.

uses the [hello-friend theme](https://github.com/panr/hugo-theme-hello-friend). 

to generate locally:

```sh
# clone the repo
git clone https://github.com/k0rventen/k0rventen.github.io
cd k0rventen.github.io

# add the theme submodule
git submodule init 
git submodule update

# render and serve on :1313
hugo server

# just render
hugo
```
