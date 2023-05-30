# frozen_string_literal: true

require_relative "ai/version"
require "tracer"
require "irb"
require "openai"
require "tty-markdown"

module IRB
  module AI
    def self.debug_mode?
      ENV["IRB_AI_DEBUG"] && !ENV["IRB_AI_DEBUG"].empty?
    end

    def self.ai_client
      @ai_client ||= OpenAI::Client.new(access_token: ENV["OPENAI_API_KEY"])
    end

    def self.register_irb_commands
      ec = IRB::ExtendCommandBundle.instance_variable_get(:@EXTEND_COMMANDS)

      [
        [
          :explain,
          :Explain,
          nil,
          [:explain, IRB::ExtendCommandBundle::OVERRIDE_ALL]
        ]
      ].each do |ecconfig|
        ec.push(ecconfig)
        IRB::ExtendCommandBundle.def_extend_command(*ecconfig)
      end
    end
  end

  module ExtendCommand
    class Explain < IRB::ExtendCommand::Nop
      IRB_PATH = Gem.loaded_specs["irb"].full_gem_path

      category "AI"
      description "WIP"

      def self.transform_args(args)
        # Return a string literal as is for backward compatibility
        if args.empty? || string_literal?(args)
          args
        else # Otherwise, consider the input as a String for convenience
          args.strip.dump
        end
      end

      def execute(*args)
        expression = args.first&.chomp

        unless expression
          puts "Please provide the expression to explain. Usage: `explain <expression>`"
          return
        end

        output = StringIO.new
        context_obj = irb_context.workspace.main
        exception = nil

        context_binding = irb_context.workspace.binding

        ObjectTracer
          .new(
            context_obj,
            output: output,
            colorize: false,
            header: "object-trace"
          )
          .start do
            ExceptionTracer
              .new(output: output, colorize: false, header: "exception-trace")
              .start do
                begin
                  eval(expression, context_binding)
                rescue Exception => e
                  exception = e
                end
              end
          end

        traces = output.string.split("\n")

        response =
          send_messages(
            expression: expression,
            context_binding: context_binding,
            context_obj: context_obj,
            traces: traces,
            exception: exception
          )

        while error = response.dig("error", "message")
          if error.match?(/reduce the length/)
            if traces.length >= 1
              puts "The generated request is too long. Trying again with reduced runtimne traces..."
              traces = traces.last(traces.length / 2)
              response =
                send_messages(
                  expression: expression,
                  context_binding: context_binding,
                  context_obj: context_obj,
                  traces: traces,
                  exception: exception
                )
            else
              puts "The generated request is too long even without runtime traces. Please try again with a shorter expression."
              return
            end
          else
            puts "OpenAI returned an error: #{error["message"]}"
            return
          end
        end

        finish_reason = response.dig("choices", 0, "finish_reason")

        case finish_reason
        when "stop"
        when "length"
        else
          puts "OpenAI did not finish processing the request (reason: #{finish_reason}). Please try again."
          return
        end

        content = response.dig("choices", 0, "message", "content")

        parsed = TTY::Markdown.parse(content)
        puts parsed
      end

      private

      def send_messages(
        expression:,
        context_binding:,
        context_obj:,
        traces:,
        exception:
      )
        messages = [
          {
            role: "system",
            content:
              "I will help you understand your Ruby application's behaviour."
          },
          {
            role: "user",
            content:
              generate_message(
                expression: expression,
                traces: traces,
                exception: exception,
                context_binding: context_binding,
                context_obj: context_obj
              )
          }
        ]

        if AI.debug_mode?
          puts "===================== Messages ======================="
          pp messages
          puts "======================================================"
        end

        puts "Getting response from OpenAI..."

        response =
          AI.ai_client.chat(
            parameters: {
              model: "gpt-3.5-turbo",
              messages: messages
            }
          )

        if AI.debug_mode?
          puts "==================== Raw Response ===================="
          pp response
          puts "======================================================"
        end

        response
      end

      def generate_message(
        expression:,
        context_binding:,
        context_obj:,
        traces:,
        exception:
      )
        information =
          information_section(
            expression: expression,
            traces: traces,
            exception: exception,
            context_binding: context_binding,
            context_obj: context_obj
          )

        request = request_section(expression: expression, exception: exception)
        <<~MSG
          ### Information

          #{information}

          ### Request

          #{request}
        MSG
      end

      def information_section(
        expression:,
        context_binding:,
        context_obj:,
        traces:,
        exception:
      )
        msg = <<~MSG
          - The expression `#{expression}` is evaluated in the context of the following code's breakpoint (binding.irb) at line #{context_binding.source_location.last}:

          ```ruby
          #{code_around_binding}
          ```

          - Here are the runtime traces when running the expression is evaluated (ignore if blank):

          #{traces}

          - The execution happened in the context of the object #{context_obj}
            - If a trace has `object-trace` header, that means the trace is about the execution of this object
            - If you see no `object-trace`, that means the object is not involved in the execution
        MSG

        if exception
          msg += <<~MSG
            - The execution caused the following exception: #{exception} (ignore if blank)
              - Exception backtrace is: #{exception&.backtrace}
              - If you see multiple `exception-trace`, that means multiple exceptions were raised during the execution
              - But only the last trace s directly associated with the exception you see above
              - Use other exception traces to understand the execution flow in general and don't assume they have direct link to the exception above
          MSG
        else
          msg += <<~MSG
            - The execution did not raise any exception
              - If you see multiple `exception-trace`, that means multiple exceptions were raised during the execution but they were all rescued
                However, they are likely expected exceptions and don't necessarily indicate problems inside the program
          MSG
        end

        msg
      end

      def request_section(expression:, exception:)
        msg = <<~MSG
          Please respond in the following format, with markdown syntax, and use code highlight when appropriate:

          ```
          This is an analysis of the program's behaviour when running the expression `#{expression}`

          ### Code Summary (skip if no program source code is given)

          <summary of the program's intended behaviour from the given code (ignore the breakpoint)>

          ### Execution Summary

          <summary of the program's actual behaviour from the given trace>

          ### Execution Details

          <detailed step-by-step explanation of the program's actual behaviour based on the source code and given trace>
          <strictly follow the below format>

          <example>
          1. The program started at line 1
          2. The program called method `foo` at line 2
          3. The program called method `bar` at line 3
          4. The trace shows that the program raised an exception at line 4
          </example>
        MSG

        msg += <<~MSG if exception
          ### Debugging Suggestion for #{exception}

          <potential causes of the error based on the program's execution details as explained in the previous section>
          <if you think the information is not sufficient, please explicit mention that and explain what information is missing>
        MSG

        msg
      end

      def code_around_binding
        original_colorize = IRB.conf[:USE_COLORIZE]
        IRB.conf[:USE_COLORIZE] = false
        binding = irb_context.workspace.binding
        file, line = binding.source_location

        File.read(file).lines[(line - 20)..(line + 4)].join
      ensure
        IRB.conf[:USE_COLORIZE] = original_colorize
      end
    end
  end
end

IRB::AI.register_irb_commands
