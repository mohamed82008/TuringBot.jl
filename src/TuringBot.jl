module TuringBot

using GitHub, HTTP, Sockets, JSON

# Authentication
const username = ENV["GITHUB_USERNAME"]
const authtoken = ENV["GITHUB_AUTH"]
const auth = GitHub.authenticate(authtoken)

const sourcerepo_name = "TuringLang/Turing.jl"
const sinkrepo_name = "TuringLang/TuringBenchmarks"

const sourcerepo = GitHub.Repo(sourcerepo_name)
const listenrepos = [sourcerepo] # can be Repos or repo names
const logging = Ref(false)
const started = Ref(false)
const active_pr_number = Ref(0)

snip(str, len) = str[1:min(len, end)]
snipsha(sha) = snip(sha, 7)
drop2(x) = x[3:end]
repo_url(repo_name) = "https://$username:$(authtoken)@github.com/$(repo_name).git"

gitclone!(path, repo_name) = run(`git clone $(repo_url(repo_name)) $(path)`)

function gitreset!(repo_name; branch_name = "master")
    run(`git fetch $(repo_url(repo_name))`)
    run(`git reset --hard origin/$branch_name`)
end
gitreset!(path, repo_name; branch_name = "master") = cd(()->gitreset!(repo_name; branch_name = branch_name), path)

function gitbranches(o="-l")
    run(`git fetch origin`)
    drop2.(readlines(`git branch $o`))
end
gitbranches(path, o) = cd(()->gitbranches(o), path)

function gitcheckout!(branch)
    branch_exists = (branch in gitbranches())
    branch_exists ? run(`git checkout $branch`) : run(`git checkout -b $branch`)
    branch_exists
end
gitcheckout!(path, branch) = cd(()->gitcheckout!(branch), path)

gitadd!() = run(`git add .`)
gitadd!(path) = cd(gitadd!, path)

gitcommit!(; message=" ") = run(`git commit -m $message`)
gitcommit!(path; message) = cd(()->gitcommit!(message=message), path)

function gitpush!(repo_name, branch; force = true)
    if force
        run(`git push -f $(repo_url(repo_name)) $branch`)
    else
        run(`git push $(repo_url(repo_name)) $branch`)
    end
end
gitpush!(path, repo_name, branch) = cd(()->gitpush!(repo_name, branch), path)

function find_pr(repo::GitHub.Repo, base, head)
    prs = GitHub.pull_requests(repo, auth=auth)[1]
    for i in 1:length(prs)
        pr = prs[i]
        if pr.head.ref == head && pr.base.ref == base
            return i
        end
    end
    return 0
end

maintainers = ["xukai92",
               "yebai",
               "emilemathieu",
               "trappmartin",
               "cpfiffer",
               "mohamed82008",
               "willtebbutt",
               "wesselb"]

function update_remote(shas)
    temp_dir = ".temp_" * splitdir(sinkrepo_name)[2]
    if isdir(temp_dir)
        gitreset!(temp_dir, sinkrepo_name)
    else
        gitclone!(temp_dir, sinkrepo_name)
    end
    error_msg = Ref(" ")
    branch_name = join(snipsha.(shas), "_")
    make_pr = Ref(false)
    errored = Ref(false)
    
    try
        gitcheckout!(temp_dir, branch_name)
    catch err
        if :msg ∈ fieldnames(typeof(err))
            error_msg[] = err.msg
        else
            error_msg[] = "Error checking out the branch $branch_name."
        end
        errored[] = true
    end
    currentdir = pwd()
    
    srcdir = joinpath(temp_dir, "src")
    isdir(srcdir) || mkdir(srcdir)
    cd(srcdir)
    try
        filename = "bench_shas.txt"
        write("bench_shas.txt", join(shas, "\n"))
        make_pr[] = true
    catch err
        if :msg ∈ fieldnames(typeof(err))
            error_msg[] = err.msg
        else
            error_msg[] = "Error writing the bench_shas.txt file."
        end
        errored[] = true
    end
    cd(currentdir)
    if make_pr[]
        try
            gitadd!(temp_dir)
            gitcommit!(temp_dir; message="Update benchmarking shas")
            try
                gitpush!(temp_dir, sinkrepo_name, branch_name)
            catch
                throw("Error pushing to remote.")
            end
            #rm(temp_path, recursive=true)
        catch err
            if :msg ∈ fieldnames(typeof(err))
                error_msg[] = err.msg
            else
                error_msg[] = "Error adding or committing changes."
            end
            errored[] = true
            make_pr[] = false
        end
    end
    gitreset!(temp_dir, sinkrepo_name)
    return errored[], error_msg[], make_pr[], branch_name
end

events = ["issue_comment"]
const github_listener = GitHub.EventListener(auth = auth,
                                repos = listenrepos,
                                events = events) do event
    kind, payload, repo = event.kind, event.payload, event.repository
    base_sha = GitHub.branch(repo, "master").commit.sha

    if kind == "issue_comment" && (payload["comment"]["user"]["login"] in maintainers) && 
        occursin("`@TuringBot benchmark`", payload["comment"]["body"]) 
        
        if !haskey(event.payload["issue"], "pull_request")
            body = "Benchmarking jobs cannot be triggered from issue comments (only PRs or commits)."
            params = Dict("body"=>body)
            issue = GitHub.issue(repo, payload["issue"]["number"])
            GitHub.create_comment(repo, issue, :issue, params=params, auth=auth)    
            return HTTP.Response(400)
        end
        
        pr = GitHub.pull_request(repo, payload["issue"]["number"])
        if event.payload["action"] != "created"
            body = "No action taken (submission was from an edit or delete)."
            params = Dict("body"=>body)
            GitHub.create_comment(repo, pr, :pr, params=params, auth=auth)
            return HTTP.Response(204)
        end

        if logging[]
            body = "Server busy. Please try again later.\n\nCC: @mohamed82008"
            params = Dict("body"=>body)
            GitHub.create_comment(repo, pr, :pr, params=params, auth=auth)
            return HTTP.Response(204)
        end
    
        sha = pr.head.sha
        errored, error_msg, make_pr, branch_name = update_remote([base_sha, sha])
        body = ""
        if errored
            body = "I could not schedule a benchmarking job."
            if error_msg != ""
                body *= "\n\nError: \n ```julia \n $error_msg \n ```"
            else
                body *= "\n\nError: unidentified"
            end
            body *= "\n\nCC: @mohamed82008"
        elseif make_pr
            body = "This PR was automatically made by @TuringBenchBot.\n\nCC: @mohamed82008"
            params = Dict("title" => "Benchmarking $(snipsha(sha)) against $(snipsha(base_sha))", 
                "head" => branch_name, "base" => "master", "body" => body, "maintainer_can_modify" => true)
            try
                i = find_pr(Repo(sinkrepo_name), params["base"], params["head"])
                if i == 0
                    new_pr = GitHub.create_pull_request(Repo(sinkrepo_name); auth=auth, params=params)
                else
                    new_pr = GitHub.pull_requests(Repo(sinkrepo_name), auth=auth)[1][i]
                end
                active_pr_number[] = payload["issue"]["number"]
                body = "A benchmarking job has been scheduled in $(new_pr.html_url.uri).\n\nCC: @mohamed82008"
            catch err
                if :msg ∈ fieldnames(typeof(err))
                    error_msg = err.msg
                else
                    error_msg = "Error creating a pull request."
                end
                body = "I could not schedule a benchmarking job."
                if error_msg != ""
                    body *= "\n\nError: \n ```julia \n $error_msg \n ```"
                else
                    body *= "\n\nError: unidentified"
                end
                body *= "\n\nCC: @mohamed82008"
            end
        else
            body = "Commit $(snipsha(sha)) and commit $(snipsha(base_sha)) have already been benchmarked before.\n\nCC: @mohamed82008"
        end
        params = Dict("body"=>body)
        GitHub.create_comment(repo, pr, :pr, params=params, auth=auth)
    end
    logging[] = true
    return HTTP.Response(200)
end

mutable struct TuringListener
    github_listener::EventListener
    result_listener::Function
end

function TuringListener(github_listener::EventListener)
    result_listener = (request) -> begin
        data = JSON.parse(IOBuffer(HTTP.payload(request)))
        if length(keys(data)) == 1 && haskey(data, "start")
            logging[] && started[] && return HTTP.Response(204)
            started[] = true
            branch_name = data["start"]
            temp_dir = ".log_" * splitdir(sinkrepo_name)[2]
            if isdir(temp_dir)
                gitreset!(temp_dir, sinkrepo_name)
            else
                gitclone!(temp_dir, sinkrepo_name)
            end
            gitcheckout!(temp_dir, branch_name)
            gitreset!(temp_dir, sinkrepo_name, branch_name=branch_name)
            results_dir = joinpath(temp_dir, "benchmark_results")
            isdir(results_dir) || mkdir(results_dir)
            cd(results_dir)
            isdir(branch_name) || mkdir(branch_name)
            cd(branch_name)
            return HTTP.Response(200)
        end
        if length(keys(data)) == 1 && haskey(data, "finish")
            !(logging[] && started[]) && return HTTP.Response(204)
            branch_name = data["finish"]
            temp_dir = ".log_" * splitdir(sinkrepo_name)[2]
            shas = String[]
            cd(joinpath("..", "..", "src")) do
                shas = strip.(readlines("bench_shas.txt"))
                rm("bench_shas.txt")
            end
            write_report!("report.md", shas, branch_name)
            cd(joinpath("..", "..", ".."))
            gitadd!(temp_dir)
            gitcommit!(temp_dir; message="Add benchmarking results for $branch_name. [ci skip]")
            try
                gitpush!(temp_dir, sinkrepo_name, branch_name)
            catch
                throw("Pushing to the remote branch $branch_name failed.")
            end
            gitreset!(temp_dir, sinkrepo_name)
            sinkrepo_url = repo(Repo(sinkrepo_name)).html_url.uri
            report_url = join([sinkrepo_url, "tree", branch_name, "benchmark_results", branch_name, "report.md"], "/")
            body = "Benchmarking job has completed. You can see a summary of the results in this [report]($report_url)."
            params = Dict("body"=>body)
            pr = GitHub.pull_request(Repo(sourcerepo_name), active_pr_number[])
            GitHub.create_comment(Repo(sourcerepo_name), pr, :pr, params=params, auth=auth)
            logging[] = false
            active_pr_number[] = 0
            started[] = false
            return HTTP.Response(200)
        end

        haskey(data, "turing") && haskey(data, "engine") || return
        logging[] && started[] || return HTTP.Response(204)
        sha = snipsha(data["turing_commit"])
        filename = getfilename(data)
        filepath = joinpath(sha, filename)
        isdir(sha) || mkdir(sha)
        cd(sha) do
            write(filename*".json", JSON.json(data)*"\n")
        end
        return HTTP.Response(200)
    end

    return TuringListener(github_listener, result_listener)
end

function getfilename(data)
    filename = join([data["name"], data["engine"]], "_")
    filename = replace(filename, [' ', ',', '('] => "_")
    filename = replace(filename, [')', '.', ':'] => "")
    filename
end

function write_report!(filename, shas, branch_name)
    path_pairs = []
    table = "| ID | time ratio |\n"
    table *= "|----|------------|\n"
    for f in readdir(snipsha(shas[1]))
        path1 = joinpath(snipsha(shas[1]), f)
        path2 = joinpath(snipsha(shas[2]), f)
        if isfile(path1)
            if isfile(path2)
                push!(path_pairs, (path1, path2))
            else
                push!(path_pairs, (path1, nothing))
            end
        else
            if isfile(path2)
                push!(path_pairs, (nothing, path2))
            end
        end
    end

    function getratio(n2, n1)
        r = round(n2 / n1, digits=2)
        if r > 1
            return string(r), " :x:"
        else
            return string(r), " :white_check_mark:"
        end
    end
    bench_commit = ""
    sinkrepo_url = repo(Repo(sinkrepo_name)).html_url.uri
    report_base_url = join([sinkrepo_url, "tree", branch_name, "benchmark_results", branch_name], "/")
    commit1_url = join([report_base_url, snipsha(shas[1])], "/")
    commit2_url = join([report_base_url, snipsha(shas[2])], "/")
    for (path1, path2) in path_pairs
        if path1 != nothing
            data1 = JSON.parse(IOBuffer(read(path1)))
            id = "`" * join([data1["name"], data1["engine"]], " - ") * "`"
            if !(haskey(data1, "turing") && haskey(data1["turing"], "elapsed"))
                @goto path1_error
            end
            time1 = data1["turing"]["elapsed"]
            if haskey(data1, "bench_commit")
                bench_commit = data1["bench_commit"]
            end
            if path2 != nothing
                data2 = JSON.parse(IOBuffer(read(path2)))
                if !(haskey(data2, "turing") && haskey(data2["turing"], "elapsed"))
                    @goto path2_error
                end
                time2 = data2["turing"]["elapsed"]
                url1 = join([commit1_url, getfilename(data1)], "/") * ".json"
                url2 = join([commit2_url, getfilename(data2)], "/") * ".json"
                ratio, symbol = getratio(time2, time1)
                table *= "$id | $ratio ([$time2]($url2) / [$time1]($url1)) $symbol |\n"
            else
                @label path2_error
                table *= "$id | NA |\n"
            end    
        else
            @label path1_error
            if path2 != nothing
                data2 = JSON.parse(IOBuffer(read(path2)))
                if haskey(data1, "bench_commit")
                    bench_commit = data2["bench_commit"]
                end
            end
            table *= "$id | NA |\n"
        end
    end
    table *= "\n"

    content = """
# Benchmark Report

## Job properties

*Turing Commits:*
- *pr:* $(shas[2])
- *master:* $(shas[1])

*TuringBenchmarks commit:* $bench_commit

## Results:

Below is a table of this job's results, obtained by running the benchmarks found in
[TuringLang/TuringBenchmarks](https://github.com/TuringLang/TuringBenchmarks). The table shows the time ratio of the 2 Turing commits benchmarked. A ratio greater than `1.0` denotes a possible regression (marked with :x:), while a ratio less than `1.0` denotes a possible improvement (marked with :white_check_mark:). Results are subject to noise so small fluctuations around `1.0` may be ignored.

$table
"""

    write(filename, content)
end

function Base.run(listener::TuringListener, host::HTTP.IPAddr, port::Int, args...; kwargs...)
    println("Listening for Turing GitHub events and benchmark results sent to $port;")
    println("GitHub whitelisted events: $(isa(listener.github_listener.events, Nothing) ? "All" : listener.github_listener.events)")
    HTTP.listen(host, port; kwargs...) do request::HTTP.Request
        response = listener.result_listener(request)
        response isa HTTP.Response && return response
        listener.github_listener.handle_request(request)
    end
end

const turing_listener = TuringListener(github_listener)

listen(port=8000) = GitHub.run(turing_listener, IPv4(127,0,0,1), port)

end # module
