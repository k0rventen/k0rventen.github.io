---
title: "Using a local LLM as a personnal engineering sidekick"
date: 2024-03-20
description: "If you're Batman, he's Robin."
tags: ["10x-engineer","llm","ollama","ai"]
---

# what & why

Lately (in the last year) I've been using openAI's chatGPT 3.5-turbo in my terminal, as kind of a personnal rubberducky/sidekick engineer. 

In my fish config I had the following function (from [my dotfiles](https://github.com/k0rventen/.dotfiles)):

```shell
# needs set -U OPENAI_KEY <KEY>
if command -q https; and command -q yq
  alias h 'hey_gpt'
  function hey_gpt --description "talk to gpt"
      set prompt (echo $argv | string join ' ')
      set gpt (https -b post api.openai.com/v1/chat/completions \
                  "Authorization: Bearer $OPENAI_KEY" \
                  model=gpt-3.5-turbo \
                  temperature:=0.25 \
                  stream:=true \
                  messages:='[{"role": "user", "content": "'$prompt'"}]')
      for chunk in $gpt
          if test $chunk = 'data: [DONE]'
              break
          else if string match -q --regex "content" $chunk
              yq -0 '.choices[0].delta.content' < (echo -n $chunk | string replace 'data: ' '' | psub)
          end
      end
  end
end
```

This allowed me to do things like this right in my terminal:

```
> h how can i extract a single file from a tar archive

To extract a single file from a .tar archive, you can use the tar command in the terminal or command line. The basic syntax for extracting a specific file is as follows:

bash
    tar -xf archive.tar path/to/file

Here's a breakdown of the command:

    tar: The command to call the tar utility.
    -x: Tells tar to extract files.
    -f: Specifies that you're going to specify the name of the archive file.
    archive.tar: The name of your tar archive. Replace archive.tar with the actual name of your tar file.
    path/to/file: The path to the file you want to extract from the archive, relative to the root of the tar archive. Replace this with the actual path to your file within the archive.

```

But earlier this month, openAI decided to change their billing policy, and instead of being a 'pay as you go' model, they switched to a 'pay first, use credits'. Well my 'invoices' for openAI were at best a couple of cents every month, and it seemed silly to pay like 2 euros, event if that would last me a couple of years.

So let's see how can we reproduce the same setup, but using local AI.


# how

the easiest way of running local LLM AFAIK is through [ollama](https://github.com/ollama/ollama).

You just download it and put it in your path and you are basically ready to go.

Something like:
```
> brew install ollama
> ollama serve &
> ollama run gemma:7b how far is the sun ?

The average distance between the Sun and Earth is approximately:

**93 million miles (150 million kilometers)**

This distance is known as an **Astronomical Unit (AU)**, which is often 
used to measure distances within our solar system.
```

Then, we just have to find an appropriate model. In my case, I want a model that can help me mostly for tech related questions, like how to use the command _X_ to do _Y_, maybe some code/manifests generation. 

We can define a `Modelfile`. It's basically a Dockerfile for LLMs. Mine looks like this:

```Dockerfile
FROM mistral:7b

PARAMETER temperature 0.2
PARAMETER top_k 30
PARAMETER top_p 0.5

SYSTEM """You are an experienced software engineer. 
You have deep knowledge regarding linux, devops tooling, and kubernetes.
Your answers should be succint and to the point. do not write more than a few lines.
If the user doesn't ask for an explanation or an example, do not provide one.
Just provide the necessary informations, like a shell command, a code snippet.
"""
```

I can now create my own tuned LLM using :
```
> ollama create -f Modelfile sidekick
```

And my wrapper has been heavily simplified to this:

```shell
function help_me --description 'talk to ollama'
      ollama run sidekick "$argv"
end
```

My workflow is now back to normal, and I can ask my sidekick stupid questions about the find / tar arguments daily:

```
> h how to find only files older than 10 days in linux using find 

 `find /path -type f -mtime +10`
```

This model consumes around 4Go of RAM when loaded, and it averages 6 tokens/sec for eval:
```
total duration:       6.938500483s
load duration:        165.753µs
prompt eval count:    17 token(s)
prompt eval duration: 1.347514s
prompt eval rate:     12.62 tokens/s
eval count:           35 token(s)
eval duration:        5.590406s
eval rate:            6.26 tokens/s
```

Obviously depending on the machine things might be slower than using openAI's API, and my machine might get a bit warm,
but now I know my questions aren't being used for $BIG_CORP_AI, and I can fine tune the behavior and responses of the model !



```
> h how to end a post about using an LLM as a sidekick engineer

 To conclude, as a Sidekick Engineer using an LLM (Large Language Model) 
in a Linux environment with DevOps tooling and Kubernetes:

1. Install the required packages for your LLM.
2. Set up authentication and access to necessary repositories.
3. Configure your LLM to interact with tools like Git, Docker, Helm, etc.
4. Use your LLM to assist in writing scripts, configuring files, or 
troubleshooting issues.
5. Ensure proper security measures are in place for sensitive data and 
access.
6. Continuously improve the effectiveness of your LLM by fine-tuning and 
updating it.
7. Monitor performance and resource usage to maintain optimal system 
health.

Happy engineering!
```

Oh well, my job ain't dead anytime soon.


## llama3 update

With the release of llama3 I've switched to this model (specifically llama3:8b) and tweaked the system prompt a bit:

This is quite an improvement over mistral/gemma. The responses are on point, usually better overall (in accurary / correctness).

Asking the same question as before:

```
> h write the conclusion of a blog post about using a local LLM as a sidekick engineer

"In conclusion, leveraging a local Large Language Model (LLM) as a sidekick engineer has 
revolutionized my workflow and productivity. By automating repetitive tasks, providing instant
language translation, and offering expert-level suggestions, my LLM sidekick has become an 
indispensable tool in my daily engineering routine. With its ability to learn from my 
interactions and adapt to my specific needs, I'm excited to see the continued evolution of 
this technology and how it will further augment my skills as a software engineer."
```

On a more tech subject:

```
> h how to copy every file ending in pdf recursively from a folder into another given directory

`find /source/folder -type f -name "*.pdf" -exec cp {} /destination/directory \;`
```

It's still not as fast as chatGPT (and certainly not as good as the 4o model), but it still serves me daily !