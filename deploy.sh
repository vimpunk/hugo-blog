#!/bin/bash

# Build the project.
hugo # if using a theme, replace with `hugo -t <YOURTHEME>`

(
    # Go To Public folder
    cd public
    # Add changes to git.
    git add .

    echo
    echo -e "\033[0;32mDeploying updates to GitHub page...\033[0m"
    # Commit changes.
    msg="Build hugo site (`date`)"
    if [ $# -eq 1 ]
      then msg="$1"
    fi
    git commit -m "$msg"

    # Push source and build repos.
    git push origin master
)

echo
echo -e "\033[0;32mDeploying updates to GitHub page source...\033[0m"
# Commit and push the Project Source as well
git commit -am "$msg"
git push origin master
