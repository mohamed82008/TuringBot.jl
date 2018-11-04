module TuringBot

using GitHub, HTTP, Sockets

# Authentication
username = ENV["GITHUB_USERNAME"]
myauth = GitHub.authenticate(ENV["GITHUB_AUTH"])

repo_name = "TuringLang/Turing.jl"
myrepos = [GitHub.Repo(repo_name)] # can be Repos or repo names
repo = myrepos[1]

snip(str, len) = str[1:min(len, end)]
snipsha(sha) = snip(sha, 7)

repo_url(repo_name) = "https://$username:$(ENV["GITHUB_AUTH"])@github.com/$(repo_name).git"
gitclone!(repo, path) = run(`git clone $(repo_url(repo)) $(path)`)
function gitreset!(repo)
    run(`git fetch $(repo_url(repo))`)
    run(`git reset --hard origin/master`)
end

gitreset!(path, repo) = cd(()->gitreset!(repo), path)
gitbranches(o="-l") = readlines(`git branch $o`) .|> (x) -> (x[3:end])
gitbranches(path, o) = cd(()->gitbranches(o), path)
function gitcheckout!(branch)
    branch_exists = (branch in gitbranches())
    branch_exists ? run(`git checkout $branch`) : run(`git checkout -b $branch`)
    branch_exists
end

gitcheckout!(path, branch) = cd(()->gitcheckout!(branch), path)
gitadd!() = run(`git add .`)
gitadd!(path) = cd(gitadd!, path)
gitcommit!(;message) = run(`git commit -m $message`)
gitcommit!(path; message="") = cd(()->gitcommit!(message=message), path)

function gitpush!(repo, branch)
    run(`git push $(repo_url(repo)) $branch`)
end
gitpush!(path, repo, branch) = cd(()->gitpush!(repo, branch), path)

function find_pr(repo, base, head)
    prs = GitHub.pull_requests(repo, auth=myauth)[1]
    for i in 1:length(prs)
        pr = prs[i]
        if pr.head.label == head && pr.base.label == base
            return i
        end
    end
    return 0
end

sink_repo_name = "TuringBenchmarks"
sink_repo = "$username/$repo_name"
function update_remote(shas)
    temp_dir = ".temp_$(sink_repo_name)"
    if isdir(temp_dir)
        gitreset!(temp_dir, sink_repo)
    else
        gitclone!(temp_dir, sink_repo)
    end
    error_msg = Ref("")
    branch_name = join(snipsha.(shas), "_")
    make_pr = Ref(false)
    errored = Ref(false)
    
    try
        gitcheckout!(temp_dir, branch_name)
    catch err
        error_msg[] = err.msg
        errored[] = true
    end
    cd(joinpath(temp_dir, "src")) do
        try
            filename = "bench_shas.txt"
            if !("origin/$branch_name" in gitbranches("..", "-r"))
                write("bench_shas.txt", join(shas, "\n"))
                make_pr[] = true
            end
        catch err
            error_msg[] = err.msg
            errored[] = true
        end
    end
    if make_pr[]
        try
            gitadd!(temp_dir)
            gitcommit!(temp_dir; message="Update benchmarking shas")
            gitpush!(temp_dir, sink_repo, branch_name)
            #rm(temp_path, recursive=true)
        catch err
            error_msg[] = err.msg
            errored[] = true
            make_pr[] = false
        end
    end
    gitreset!(temp_dir, sink_repo)
    #run(`rm -r $temp_dir`)
    return errored[], error_msg[], make_pr[], branch_name
end

maintainers = ["xukai92",
               "yebai",
               "emilemathieu",
               "trappmartin",
               "cpfiffer",
               "mohamed82008",
               "willtebbutt",
               "wesselb"]

myevents = ["issue_comment"]
listener = GitHub.EventListener(auth = myauth,
                                repos = myrepos,
                                events = myevents) do event
    kind, payload, repo = event.kind, event.payload, event.repository
    base_sha = GitHub.branch(repo, "master").commit.sha

    if kind == "issue_comment" && (payload["comment"]["user"]["login"] in maintainers) && 
        occursin("`@TuringBot benchmark`", payload["comment"]["body"]) 
        if !haskey(event.payload["issue"], "pull_request")
            body = "Benchmarking jobs cannot be triggered from issue comments (only PRs or commits)"
            params = Dict("body"=>body)
            issue = GitHub.issue(repo, payload["issue"]["number"])
            GitHub.create_comment(repo, issue, :issue, params=params, auth=myauth)    
            return HTTP.Response(400)
        end
        
        pr = GitHub.pull_request(repo, payload["issue"]["number"])
        if event.payload["action"] != "created"
            body = "No action taken (submission was from an edit or delete)."
            params = Dict("body"=>body)
            GitHub.create_comment(repo, pr, :pr, params=params, auth=myauth)
            return HTTP.Response(204)
        end
        
        sha = pr.head.sha
        errored, error_msg, make_pr, branch_name = update_remote([base_sha, sha])
        body = ""
        if errored
            body *= "I could not schedule a benchmarking job."
            if error_msg != ""
                body *= "\n\nError: \n ```julia \n $error_msg \n ```"
            else
                body *= "\n\nError: unidentified"
            end
        elseif make_pr
            body *= "This PR was automatically made by @TuringBenchBot."
            params = Dict("title" => "Benchmarking $(snipsha(sha)) against $(snipsha(base_sha))", 
                "head" => branch_name, "base" => "master", "body" => body, "maintainer_can_modify" => true)
            try
                i = find_pr(Repo(sink_repo), params["base"], params["head"])
                if i == 0
                    new_pr = GitHub.create_pull_request(Repo(sink_repo); auth=myauth, params=params)
                else
                    new_pr = GitHub.pull_requests(repo, auth=myauth)[1][i]
                end
                body = "A benchmarking job has been scheduled in $(new_pr.html_url.uri)."
            catch err
                error_msg = err.msg
                body *= "I could not schedule a benchmarking job."
                if error_msg != ""
                    body *= "\n\nError: \n ```julia \n $error_msg \n ```"
                else
                    body *= "\n\nError: unidentified"
                end
            end
        else
            body *= "Commit $(snipsha(sha)) and commit $(snipsha(base_sha)) have already been benchmarked before."
        end
        params = Dict("body"=>body)
        GitHub.create_comment(repo, pr, :pr, params=params, auth=myauth)            
    end
    return HTTP.Response(200)
end

listen() = GitHub.run(listener, IPv4(127,0,0,1), 8000)

end # module
